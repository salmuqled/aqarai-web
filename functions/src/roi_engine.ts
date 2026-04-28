/**
 * Deterministic ROI / Yield engine — Phase 1.
 *
 * Pure math over Firestore data. Never calls OpenAI. Numbers returned by this
 * module are authoritative — the LLM chat layer (`agent_brain.ts`) quotes them
 * verbatim and is instructed to never invent yield/payback numbers.
 *
 * Two data paths, preferred in order:
 *   1. `owner` — the owner filled `estimatedMonthlyIncomeKwd` on the listing.
 *   2. `comparables` — at least 3 same-area same-type monthly rentals; use the
 *      median monthly rent × `unitCount` (defaults to 1 when absent).
 *
 * When neither path qualifies we return null (callers must say "no data"; the
 * LLM is forbidden from guessing).
 *
 * Comparable query rules are intentionally strict (see plan §B.3):
 *   - same `areaCode` (no cluster expansion — coastal vs inland rents differ)
 *   - same `type`
 *   - `serviceType == 'rent'` AND `rentalType == 'monthly'`
 *   - `size` within ±30% of the target listing (when target has a size)
 *   - `approved == true`, `isActive == true`
 *   - ≥ 3 after all filters applied; otherwise null
 *   - median to resist outliers
 *
 * Results are cached on the property document under `roi` for 7 days; cache is
 * invalidated on every listing write (handled outside this module).
 */

import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

const db = admin.firestore();

// Cache TTL: 7 days. Short enough to react to market shifts, long enough to
// absorb repeat traffic on the same listing without hammering Firestore.
const ROI_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

// Minimum comparable sample size. Below this we refuse to compute — a yield
// derived from 1–2 rentals is noise, and showing an unreliable number would
// damage the agent's trust more than saying "no data".
const MIN_COMPARABLES = 3;

// Size tolerance for comparable filtering: ±30 % of target listing size.
const SIZE_TOLERANCE = 0.3;

export type RoiSource = "owner" | "comparables";

export interface RoiResult {
  yieldPercent: number; // e.g. 7.5 means 7.5%
  annualIncomeKwd: number;
  paybackYears: number;
  source: RoiSource;
  comparableCount?: number;
  computedAt: number; // ms epoch
}

// Shape we inject into the LLM compose prompt as plain text. Keep field
// names short so they survive prompt truncation.
export interface RoiFactsBlock {
  yield: string; // "7.5%"
  annual: string; // "24000"
  payback: string; // "13.3y"
  source: string; // "owner_provided" | "market_comparables"
  sampleSize?: number;
}

function toNum(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number(v.replace(/,/g, "").trim());
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid];
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

interface TargetListing {
  id: string;
  type: string;
  serviceType: string;
  areaCode: string;
  price: number;
  size: number | null;
  unitCount: number;
  estimatedMonthlyIncomeKwd: number | null;
  cachedRoi: RoiResult | null;
}

function readTargetListing(
  snap: FirebaseFirestore.DocumentSnapshot
): TargetListing | null {
  if (!snap.exists) return null;
  const data = snap.data() as Record<string, unknown>;
  const type = String(data.type || "").trim();
  const serviceType = String(data.serviceType || "").trim();
  const areaCode = String(data.areaCode || "").trim();
  const price = toNum(data.price) ?? 0;
  if (!type || serviceType !== "sale" || !areaCode || price <= 0) {
    return null;
  }
  const unitCount = toNum(data.unitCount);
  const estimated = toNum(data.estimatedMonthlyIncomeKwd);
  const size = toNum(data.size);
  const cached = (data.roi as RoiResult | undefined) || null;
  return {
    id: snap.id,
    type,
    serviceType,
    areaCode,
    price,
    size: size != null && size > 0 ? size : null,
    unitCount: unitCount != null && unitCount > 0 ? Math.floor(unitCount) : 1,
    estimatedMonthlyIncomeKwd:
      estimated != null && estimated > 0 ? estimated : null,
    cachedRoi: cached,
  };
}

function isCacheFresh(cached: RoiResult | null): cached is RoiResult {
  return !!(
    cached &&
    typeof cached.computedAt === "number" &&
    Date.now() - cached.computedAt < ROI_CACHE_TTL_MS
  );
}

function buildFromOwnerInput(target: TargetListing): RoiResult | null {
  if (target.estimatedMonthlyIncomeKwd == null) return null;
  const annual = target.estimatedMonthlyIncomeKwd * 12;
  if (annual <= 0 || target.price <= 0) return null;
  return {
    yieldPercent: round2((annual / target.price) * 100),
    annualIncomeKwd: round2(annual),
    paybackYears: round2(target.price / annual),
    source: "owner",
    computedAt: Date.now(),
  };
}

/**
 * Pick the correct comparable `type` for a target listing. When the target
 * is a multi-unit listing (building, or any listing with `unitCount > 1`)
 * we compare against same-area `apartment` monthly rentals — then multiply
 * the median per-unit rent by `unitCount`. Single-unit listings compare
 * against same-type rentals directly.
 *
 * This mirrors the plan's `avg monthly rent × unitCount` math: for a 4-unit
 * building priced at 200k KWD, a reliable yield comes from per-unit rents,
 * not from the near-empty pool of whole-building rentals.
 */
function comparableTypeFor(target: TargetListing): string {
  if (target.type === "building" || target.unitCount > 1) return "apartment";
  return target.type;
}

async function fetchComparableMonthlyRents(
  target: TargetListing
): Promise<number[]> {
  const compType = comparableTypeFor(target);
  // Strict equality on area + type + service + rentalType. We intentionally
  // do NOT expand areaCode into clusters here — comparables must be tight.
  const query = db
    .collection("properties")
    .where("approved", "==", true)
    .where("isActive", "==", true)
    .where("serviceType", "==", "rent")
    .where("rentalType", "==", "monthly")
    .where("type", "==", compType)
    .where("areaCode", "==", target.areaCode)
    .limit(50);

  const snap = await query.get();
  const rents: number[] = [];
  // Apply size tolerance only when comparing same type. When we substitute
  // apartment comparables for a building target, sizes are not directly
  // comparable (building lot size vs apartment floor size), so we skip the
  // size filter in that case.
  const applySizeFilter = compType === target.type && target.size != null;
  for (const doc of snap.docs) {
    if (doc.id === target.id) continue;
    const d = doc.data() as Record<string, unknown>;
    if (applySizeFilter) {
      const compSize = toNum(d.size);
      if (compSize == null || compSize <= 0) continue;
      const low = target.size! * (1 - SIZE_TOLERANCE);
      const high = target.size! * (1 + SIZE_TOLERANCE);
      if (compSize < low || compSize > high) continue;
    }
    const rent = toNum(d.price);
    if (rent == null || rent <= 0) continue;
    rents.push(rent);
  }
  return rents;
}

async function buildFromComparables(
  target: TargetListing
): Promise<RoiResult | null> {
  const rents = await fetchComparableMonthlyRents(target);
  if (rents.length < MIN_COMPARABLES) return null;
  // Median monthly rent per unit × unit count → total monthly income.
  const medianMonthlyPerUnit = median(rents);
  const monthlyTotal = medianMonthlyPerUnit * target.unitCount;
  const annual = monthlyTotal * 12;
  if (annual <= 0 || target.price <= 0) return null;
  return {
    yieldPercent: round2((annual / target.price) * 100),
    annualIncomeKwd: round2(annual),
    paybackYears: round2(target.price / annual),
    source: "comparables",
    comparableCount: rents.length,
    computedAt: Date.now(),
  };
}

/**
 * Compute ROI for a single property document.
 *
 * Returns null when:
 *   - listing is not a sale listing
 *   - sale price missing or zero
 *   - neither owner-provided income nor enough comparables available
 *
 * `forceRefresh` bypasses the 7-day cache — useful for admin tools / tests.
 */
export async function computeRoiForProperty(
  propertyId: string,
  forceRefresh = false
): Promise<RoiResult | null> {
  const ref = db.collection("properties").doc(propertyId);
  const snap = await ref.get();
  const target = readTargetListing(snap);
  if (!target) return null;

  if (!forceRefresh && isCacheFresh(target.cachedRoi)) {
    return target.cachedRoi;
  }

  const result =
    buildFromOwnerInput(target) ?? (await buildFromComparables(target));

  if (result) {
    // Cache on the property doc — listing edits must bump a companion watcher
    // or call with `forceRefresh: true`. Failures here are non-fatal: the
    // caller has a valid `RoiResult` either way.
    try {
      await ref.set({ roi: result }, { merge: true });
    } catch {
      /* cache write best-effort */
    }
  }

  return result;
}

export function roiToFactsBlock(result: RoiResult): RoiFactsBlock {
  return {
    yield: `${result.yieldPercent}%`,
    annual: String(result.annualIncomeKwd),
    payback: `${result.paybackYears}y`,
    source: result.source === "owner" ? "owner_provided" : "market_comparables",
    sampleSize: result.comparableCount,
  };
}

/** Callable wrapper used by the client / chat layer. */
export const aqaraiAgentComputeRoi = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }
    const data = (request.data as Record<string, unknown>) || {};
    const propertyId =
      typeof data.propertyId === "string" ? data.propertyId.trim() : "";
    const forceRefresh = data.forceRefresh === true;
    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId required");
    }
    const result = await computeRoiForProperty(propertyId, forceRefresh);
    return { roi: result };
  }
);
