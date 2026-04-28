/**
 * In-memory ranking, labels, best-deal detection. findSimilar can run Firestore via injected db.
 */
import type { Firestore, QueryDocumentSnapshot } from "firebase-admin/firestore";
import { isNormalListingMarketplaceVisible } from "./propertyVisibility";

/** Exclude corrupt, missing, or non-positive prices from ranked agent results. */
export function listingPricePositiveFinite(prop: Record<string, unknown>): boolean {
  const raw = prop.price;
  const n =
    typeof raw === "number"
      ? raw
      : typeof raw === "string"
        ? Number(raw)
        : Number(raw);
  return typeof n === "number" && Number.isFinite(n) && n > 0;
}

function toMillis(v: unknown): number | null {
  if (v == null) return null;
  if (typeof v === "number" && !Number.isNaN(v)) return v;
  if (typeof v === "string") {
    const ms = Date.parse(v);
    return Number.isNaN(ms) ? null : ms;
  }
  if (typeof v === "object" && v !== null && "_seconds" in v) {
    const s = (v as { _seconds?: number })._seconds;
    return typeof s === "number" ? s * 1000 : null;
  }
  return null;
}

function scoreProperty(
  prop: Record<string, unknown>,
  requestedAreaCode: string,
  nearbyAreaCodes: string[],
  userBudget: number | null,
  nowMs: number
): number {
  let score = 0;
  const areaCode = (prop.areaCode as string) || "";
  if (requestedAreaCode && areaCode === requestedAreaCode) score += 50;
  if (nearbyAreaCodes.length > 0 && nearbyAreaCodes.includes(areaCode)) score += 20;
  const featuredUntil = toMillis(prop.featuredUntil);
  if (featuredUntil != null && featuredUntil > nowMs) score += 30;
  const createdAt = toMillis(prop.createdAt);
  if (createdAt != null && nowMs - createdAt <= 7 * 24 * 60 * 60 * 1000) score += 10;
  const price = typeof prop.price === "number" ? prop.price : Number(prop.price);
  if (userBudget != null && userBudget > 0 && !Number.isNaN(price) && price <= userBudget) score += 10;
  return score;
}

export function rankPropertyResults(
  properties: Record<string, unknown>[],
  options: {
    requestedAreaCode?: string;
    nearbyAreaCodes?: string[];
    userBudget?: number | null;
    nowMs?: number;
  }
): Record<string, unknown>[] {
  const {
    requestedAreaCode = "",
    nearbyAreaCodes = [],
    userBudget = null,
    nowMs = Date.now(),
  } = options;
  if (properties.length === 0) return [];
  const withScore = properties.map((p) => ({
    prop: p,
    score: scoreProperty(p, requestedAreaCode, nearbyAreaCodes, userBudget, nowMs),
    createdAtMs: toMillis(p.createdAt) ?? 0,
  }));
  withScore.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score;
    return b.createdAtMs - a.createdAtMs;
  });
  return withScore.slice(0, 3).map((x) => x.prop);
}

export type PropertyLabelId = "new_listing" | "high_demand" | "good_deal";

export function computePropertyLabels(
  property: Record<string, unknown>,
  marketSignal: string,
  nowMs: number,
  averagePriceSameArea?: number | null
): PropertyLabelId[] {
  const labels: PropertyLabelId[] = [];
  const createdAt = toMillis(property.createdAt);
  if (createdAt != null && nowMs - createdAt <= 7 * 24 * 60 * 60 * 1000) labels.push("new_listing");
  if (marketSignal === "high_demand_low_supply") labels.push("high_demand");
  if (averagePriceSameArea != null && averagePriceSameArea > 0) {
    const price = typeof property.price === "number" ? property.price : Number(property.price);
    if (!Number.isNaN(price) && price < averagePriceSameArea) labels.push("good_deal");
  }
  return labels.slice(0, 2);
}

export function computeAveragePrice(properties: Record<string, unknown>[]): number | null {
  if (!properties || properties.length === 0) return null;
  const prices = properties
    .map((p) => (typeof p.price === "number" ? p.price : Number(p.price)))
    .filter((p) => typeof p === "number" && !Number.isNaN(p));
  if (prices.length === 0) return null;
  return prices.reduce((a, b) => a + b, 0) / prices.length;
}

export function detectBestDeal(
  properties: Record<string, unknown>[],
  averagePrice: number
): Record<string, unknown> | null {
  if (!averagePrice) return null;
  const deal = properties.find((p) => {
    const price = typeof p.price === "number" ? p.price : Number(p.price);
    if (typeof price !== "number" || Number.isNaN(price)) return false;
    return averagePrice - price > averagePrice * 0.05;
  });
  return deal ?? null;
}

// ---------------------------------------------------------------------------
// Similar properties (uses Firestore when db provided)
// ---------------------------------------------------------------------------

export interface FindSimilarParams {
  requestedAreaCode: string;
  propertyType: string;
  userBudget?: number | null;
  nearbyAreaCodes: string[];
  requestedSize?: number | null;
}

function scoreSimilarProperty(
  prop: Record<string, unknown>,
  userBudget: number | null,
  requestedSize: number | null,
  nowMs: number
): number {
  let score = 40;
  const price = typeof prop.price === "number" ? prop.price : Number(prop.price);
  if (userBudget != null && userBudget > 0 && !Number.isNaN(price)) {
    const low = userBudget * 0.9;
    const high = userBudget * 1.1;
    if (price >= low && price <= high) score += 20;
  }
  if (requestedSize != null && requestedSize > 0) {
    const size = typeof prop.size === "number" ? prop.size : Number(prop.size);
    if (!Number.isNaN(size) && size > 0) {
      const diff = Math.abs(size - requestedSize) / requestedSize;
      if (diff < 0.2) score += 10;
    }
  }
  const createdAt = toMillis(prop.createdAt);
  if (createdAt != null && nowMs - createdAt <= 14 * 24 * 60 * 60 * 1000) score += 10;
  return score;
}

/** Fetch and rank similar properties in nearby areas. Requires db for Firestore + optional getMarketSignal. */
export async function findSimilarProperties(
  params: FindSimilarParams,
  db: Firestore,
  getMarketSignal?: (areaCode: string, propertyType: string) => Promise<string>
): Promise<Record<string, unknown>[]> {
  const { propertyType, userBudget, nearbyAreaCodes, requestedSize } = params;
  const areas = (nearbyAreaCodes || []).filter((a) => a != null && String(a).trim() !== "");
  if (areas.length === 0) return [];

  // Phase 1 generalization: propertyType is optional. When the user gave us
  // just an area (no type preference), we still surface nearby listings and
  // let downstream ranking/composition adapt. When it's provided, we keep
  // the strict equality filter for precision.
  const typeTrim = propertyType?.trim() ?? "";
  const areaList = areas.length > 10 ? areas.slice(0, 10) : areas;
  const perAreaLimit = Math.max(4, Math.ceil(24 / areaList.length));
  const merged: QueryDocumentSnapshot[] = [];
  const seen = new Set<string>();
  for (const area of areaList) {
    let q = db
      .collection("properties")
      .where("approved", "==", true)
      .where("isActive", "==", true)
      .where("listingCategory", "==", "normal")
      .where("hiddenFromPublic", "==", false)
      .where("areaCode", "==", area);
    if (typeTrim) q = q.where("type", "==", typeTrim);
    const snap = await q.limit(perAreaLimit).get();
    for (const d of snap.docs) {
      if (seen.has(d.id)) continue;
      seen.add(d.id);
      merged.push(d);
    }
  }
  const docs = merged
    .filter((d) => isNormalListingMarketplaceVisible(d.data()))
    .map((d) => ({ id: d.id, ...d.data() } as Record<string, unknown>))
    .filter(listingPricePositiveFinite);

  const budget = userBudget != null && userBudget > 0 ? userBudget : null;
  let filtered = docs;
  if (budget != null) {
    const low = budget * 0.8;
    const high = budget * 1.2;
    filtered = docs.filter((p) => {
      const price = typeof p.price === "number" ? p.price : Number(p.price);
      return !Number.isNaN(price) && price >= low && price <= high;
    });
  }

  const nowMs = Date.now();
  const reqSize = requestedSize != null && requestedSize > 0 ? requestedSize : null;
  const withScore = filtered.map((p) => ({
    prop: p,
    score: scoreSimilarProperty(p, budget, reqSize, nowMs),
    createdAtMs: toMillis(p.createdAt) ?? 0,
  }));
  withScore.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score;
    return b.createdAtMs - a.createdAtMs;
  });
  const recommendations = withScore.slice(0, 3).map((x) => x.prop);

  let marketSignal = "normal";
  if (getMarketSignal && params.requestedAreaCode?.trim() && typeTrim) {
    try {
      marketSignal = await getMarketSignal(params.requestedAreaCode.trim(), typeTrim);
    } catch {
      // non-fatal
    }
  }
  for (const prop of recommendations) {
    const areaCode = (prop.areaCode as string) || "";
    const sameArea = recommendations.filter((p) => ((p.areaCode as string) || "") === areaCode);
    const prices = sameArea
      .map((p) => (typeof p.price === "number" ? p.price : Number(p.price)))
      .filter((n) => !Number.isNaN(n));
    const avgPrice = prices.length > 0 ? prices.reduce((a, b) => a + b, 0) / prices.length : null;
    prop.labels = computePropertyLabels(prop, marketSignal, nowMs, avgPrice);
  }
  return recommendations;
}
