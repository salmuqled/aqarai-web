/**
 * Smart Suggestions Engine.
 *
 * Goal: turn the chat from a "static result display" into a real estate
 * assistant. When a user's search returns zero or weak (< threshold) results,
 * this module derives *actionable* alternatives (shift dates, bump budget,
 * widen area) and bilingual copy explaining what changed and why.
 *
 * Design principles (match the brief):
 *
 *   1. DETERMINISTIC.  No LLM call. Every alternative is derivable from the
 *      input filters by documented arithmetic + a known neighbor map. This
 *      is cheap (no token cost), auditable, and safe to run on every thin
 *      chat turn.
 *
 *   2. USE REAL DATA.  The availability-shift strategy does not just guess —
 *      when the caller forwards the current `candidatePropertyIds` pool
 *      (the pre-availability-gate result set the client just fetched), we
 *      probe each shifted window against the same authoritative primitive
 *      (`fetchUnavailablePropertyIdsBatched`) used by `searchDailyProperties`
 *      and `filterChatAvailability`. We emit the shift with the highest
 *      post-filter count. This turns "+1 day" from a blind suggestion into
 *      "+1 day has 4 available chalets from your shortlist".
 *
 *   3. REUSE EXISTING PRIMITIVES.  No new overlap math, no new Firestore
 *      schema. Date Intelligence Layer already produced the ISO triple and
 *      shared_availability already owns the booking/block overlap query.
 *
 *   4. SAFE DEFAULTS.  If the filters don't support a strategy (e.g. no
 *      maxPrice, no areaCode, no date range), that strategy silently drops.
 *      If no strategy applies, we still return a `failureReason: 'unknown'`
 *      and an empty `alternatives[]` — caller decides whether to show the
 *      banner or fall back to the existing "no results" copy.
 *
 *   5. NO HARDCODED RESPONSES.  Each alternative's copy is composed from a
 *      template + the *actual* shifted/bumped/widened values (e.g. "من 29
 *      إلى 31" is rendered from the computed dates, not a canned string).
 *
 * Callers: `agent_brain.aqaraiAgentAnalyze` forwards filters to the
 * client, which then invokes `generateChatSmartSuggestions` only when the
 * post-gate result count is weak. The callable is thin so it can also be
 * called from other surfaces (email digests, push notifications) later.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import {
  fetchUnavailablePropertyIdsBatched,
  parseIsoToTimestamp,
} from "./shared_availability";

const db = admin.firestore();

/** Max alternatives we return across all strategies (UI renders as chips). */
const MAX_ALTERNATIVES = 3;

/** Default threshold below which we consider a result set "weak". */
export const SMART_SUGGESTIONS_WEAK_THRESHOLD = 3;

/** Date-shift probe offsets (in days). Nights are preserved on every shift. */
const DATE_SHIFT_OFFSETS_DAYS = [1, 2, 3];

/** Budget bumps as multiplicative ratios. Keep ordered ascending. */
const BUDGET_BUMP_RATIOS = [1.1, 1.2];

/** Max size of `candidatePropertyIds` to probe. Caps Firestore reads. */
const CANDIDATE_POOL_HARD_CAP = 120;

/**
 * Property-type → allowed area allowlist used by the area-widen strategy.
 *
 * Purpose: kill the "ابي شاليه → وسّع للرابية" class of bug. The client's
 * nearby-area map is a generic neighbor graph; it has no notion that
 * chalets only exist in coastal / beach zones, and residential apartments
 * only exist in city neighborhoods. Applying it naively produces logically
 * broken suggestions (a chalet in Rabia does not exist).
 *
 * Rule: when `filters.propertyType` is set, the area-widen strategy will
 * ONLY propose an `areaCode` from the list below. If the client-supplied
 * `nearbyAreaCodes` intersects the allowlist, we take the first match.
 * If it does NOT, we drop the strategy entirely (return null) — better no
 * suggestion than a wrong one.
 *
 * Keys use the same lowercase tokens the rest of the system uses for
 * Firestore `type`: `chalet`, `apartment`, `house`, `villa`. `villa` is an
 * alias for `house` because the user-facing vocabulary uses it but the
 * listings schema stores `house`.
 *
 * Area tokens match Firestore `areaCode` values — keep them lowercase.
 */
const AREA_BY_PROPERTY_TYPE: Readonly<Record<string, readonly string[]>> = {
  chalet: ["khairan", "sabah_ahmad_sea", "zour", "bnaider"],
  apartment: ["hawally", "salmiya", "jabriya", "rabia"],
  house: ["mishref", "jabriya", "south_surra"],
  villa: ["mishref", "jabriya", "south_surra"],
};

/**
 * Returns the allowlist of area codes compatible with [propertyType], or
 * `null` if [propertyType] is empty / not recognized (meaning: no gating —
 * fall back to accepting any neighbor the caller proposed).
 */
function allowedAreaCodesForPropertyType(
  propertyType: string | undefined | null
): readonly string[] | null {
  const key = (propertyType ?? "").toString().trim().toLowerCase();
  if (!key) return null;
  const list = AREA_BY_PROPERTY_TYPE[key];
  return list && list.length > 0 ? list : null;
}

export type FailureReason =
  | "availability"
  | "budget"
  | "area"
  | "none"
  | "unknown";

export type AlternativeKind =
  | "availability_shift"
  | "budget_bump"
  | "area_widen";

/**
 * Filter snapshot understood by both server strategies and the chat
 * client. Mirrors the Date Intelligence Layer triple + the existing filter
 * fields. We pass only the subset that's actually used to derive
 * alternatives — other fields (governorateCode, bedrooms…) are forwarded
 * opaquely so the client can re-run the same query with the patch applied.
 */
export interface SuggestionFilters {
  serviceType?: string;
  propertyType?: string;
  rentalType?: string;
  areaCode?: string;
  governorateCode?: string;
  maxPrice?: number;
  bedrooms?: number;
  /** ISO-8601 UTC midnight. */
  startDate?: string;
  /** ISO-8601 UTC midnight, exclusive. */
  endDate?: string;
  /** Integer nights in `[startDate, endDate)`. */
  nights?: number;
}

export interface SuggestionAlternative {
  kind: AlternativeKind;
  /** Filter patch to apply; all original fields NOT listed here remain. */
  filters: SuggestionFilters;
  /** One-liner rendered as a chip / banner line. */
  headline_ar: string;
  headline_en: string;
  /** Optional extra context rendered in a secondary line. */
  detail_ar: string;
  detail_en: string;
  /** For availability shifts: number of candidates free in this window. */
  availabilityCount?: number;
}

export interface GenerateSmartSuggestionsInput {
  filters: SuggestionFilters;
  originalResultCount: number;
  /**
   * The property IDs the client just fetched (pre- or post-availability-
   * gate both work). Used to give the availability-shift probe real data.
   * Optional: omit to fall back to the analytic (non-probed) shift list.
   */
  candidatePropertyIds?: string[];
  /** Client-curated nearby area codes. We don't own an area graph server-side. */
  nearbyAreaCodes?: string[];
  /** Inclusive cap on alternatives. Defaults to [MAX_ALTERNATIVES]. */
  maxAlternatives?: number;
}

export interface GenerateSmartSuggestionsOutput {
  failureReason: FailureReason;
  alternatives: SuggestionAlternative[];
  banner_ar: string;
  banner_en: string;
  /** True when the result count did not cross the weak threshold. */
  triggered: boolean;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * True for listings whose availability semantics depend on a calendar window
 * (chalet or daily rental). Monthly rentals and sales short-circuit: a date
 * shift has no meaning for them. Mirrors the client's `_isDateBookableDoc`.
 */
function isDateBookable(f: SuggestionFilters): boolean {
  const type = (f.propertyType ?? "").trim().toLowerCase();
  const rentalType = (f.rentalType ?? "").trim().toLowerCase();
  const serviceType = (f.serviceType ?? "").trim().toLowerCase();
  if (serviceType && serviceType !== "rent") return false;
  return type === "chalet" || rentalType === "daily";
}

/** True only when all three date fields are present and consistent. */
function hasValidDateRange(f: SuggestionFilters): boolean {
  if (!f.startDate || !f.endDate || f.nights == null) return false;
  const s = parseIsoToTimestamp(f.startDate);
  const e = parseIsoToTimestamp(f.endDate);
  if (!s || !e) return false;
  if (s.toMillis() >= e.toMillis()) return false;
  const n = Math.round((e.toMillis() - s.toMillis()) / (24 * 60 * 60 * 1000));
  return n === f.nights && n >= 1 && n <= 90;
}

function shiftIsoByDays(iso: string, days: number): string | null {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return null;
  return new Date(ms + days * 24 * 60 * 60 * 1000).toISOString();
}

/** "27 أبريل" / "Apr 27" – compact localized day/month rendering. */
function formatShortDate(iso: string, locale: "ar" | "en"): string {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return iso;
  const d = new Date(ms);
  const day = d.getUTCDate();
  const monthIdx = d.getUTCMonth();
  const ar = [
    "يناير",
    "فبراير",
    "مارس",
    "أبريل",
    "مايو",
    "يونيو",
    "يوليو",
    "أغسطس",
    "سبتمبر",
    "أكتوبر",
    "نوفمبر",
    "ديسمبر",
  ];
  const en = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  return locale === "ar" ? `${day} ${ar[monthIdx]}` : `${en[monthIdx]} ${day}`;
}

function prettyMoneyKwd(n: number): string {
  if (!Number.isFinite(n)) return String(n);
  return (Math.round(n * 100) / 100).toString();
}

// ---------------------------------------------------------------------------
// Strategy: availability shift
// ---------------------------------------------------------------------------

/**
 * Try shifting the travel window by +1/+2/+3 days (preserving `nights`).
 * When `candidatePropertyIds` is provided, we probe the *real* booking /
 * blocked_dates state for each shift and pick the shift with the highest
 * availability count. When the pool isn't provided, we emit a single
 * analytic "+1 day" suggestion without a count.
 *
 * Guard rails:
 *   - Caps probes to `DATE_SHIFT_OFFSETS_DAYS.length` shifts.
 *   - Skips if dates don't satisfy [hasValidDateRange].
 *   - Returns at most ONE alternative (the best shift).
 */
async function buildAvailabilityShiftAlternative(
  filters: SuggestionFilters,
  candidatePool: string[]
): Promise<SuggestionAlternative | null> {
  if (!isDateBookable(filters)) return null;
  if (!hasValidDateRange(filters)) return null;

  const start = filters.startDate!;
  const end = filters.endDate!;
  const nights = filters.nights!;

  const pool = candidatePool.length > 0
    ? candidatePool.slice(0, CANDIDATE_POOL_HARD_CAP)
    : [];

  type Probe = {
    offset: number;
    shiftedStart: string;
    shiftedEnd: string;
    availabilityCount: number | null;
  };
  const probes: Probe[] = [];
  for (const offset of DATE_SHIFT_OFFSETS_DAYS) {
    const s = shiftIsoByDays(start, offset);
    const e = shiftIsoByDays(end, offset);
    if (!s || !e) continue;
    probes.push({
      offset,
      shiftedStart: s,
      shiftedEnd: e,
      availabilityCount: null,
    });
  }

  if (pool.length > 0) {
    const nowMs = Date.now();
    await Promise.all(
      probes.map(async (p) => {
        const ts = parseIsoToTimestamp(p.shiftedStart);
        const te = parseIsoToTimestamp(p.shiftedEnd);
        if (!ts || !te) {
          p.availabilityCount = 0;
          return;
        }
        const unavailable = await fetchUnavailablePropertyIdsBatched(
          db,
          pool,
          ts,
          te,
          nowMs
        );
        p.availabilityCount = pool.length - unavailable.size;
      })
    );
    probes.sort((a, b) => {
      const ca = a.availabilityCount ?? -1;
      const cb = b.availabilityCount ?? -1;
      if (cb !== ca) return cb - ca;
      return Math.abs(a.offset) - Math.abs(b.offset);
    });
    const best = probes[0];
    if (!best || (best.availabilityCount ?? 0) <= 0) return null;
    return composeAvailabilityShiftAlt(
      filters,
      best.offset,
      best.shiftedStart,
      best.shiftedEnd,
      nights,
      best.availabilityCount
    );
  }

  // Analytic fallback: emit +1 day if nothing to probe.
  const fallback = probes[0];
  if (!fallback) return null;
  return composeAvailabilityShiftAlt(
    filters,
    fallback.offset,
    fallback.shiftedStart,
    fallback.shiftedEnd,
    nights,
    null
  );
}

function composeAvailabilityShiftAlt(
  original: SuggestionFilters,
  offsetDays: number,
  shiftedStart: string,
  shiftedEnd: string,
  nights: number,
  availabilityCount: number | null
): SuggestionAlternative {
  const sAr = formatShortDate(shiftedStart, "ar");
  const eAr = formatShortDate(shiftedEnd, "ar");
  const sEn = formatShortDate(shiftedStart, "en");
  const eEn = formatShortDate(shiftedEnd, "en");
  const headline_ar = `جرّب من ${sAr} إلى ${eAr}`;
  const headline_en = `Try ${sEn} to ${eEn}`;
  const detail_ar = availabilityCount != null
    ? `نفس ${nights} ${nights === 1 ? "ليلة" : "ليالٍ"} • ${availabilityCount} شاليه متاح من قائمتك`
    : `نفس ${nights} ${nights === 1 ? "ليلة" : "ليالٍ"} • تأخير ${offsetDays} ${offsetDays === 1 ? "يوم" : "أيام"}`;
  const detail_en = availabilityCount != null
    ? `Same ${nights} ${nights === 1 ? "night" : "nights"} • ${availabilityCount} chalet${availabilityCount === 1 ? "" : "s"} free from your shortlist`
    : `Same ${nights} ${nights === 1 ? "night" : "nights"} • ${offsetDays}-day shift`;
  return {
    kind: "availability_shift",
    filters: {
      ...original,
      startDate: shiftedStart,
      endDate: shiftedEnd,
      nights,
    },
    headline_ar,
    headline_en,
    detail_ar,
    detail_en,
    ...(availabilityCount != null ? { availabilityCount } : {}),
  };
}

// ---------------------------------------------------------------------------
// Strategy: budget bump
// ---------------------------------------------------------------------------

function buildBudgetBumpAlternative(
  filters: SuggestionFilters
): SuggestionAlternative | null {
  const raw = filters.maxPrice;
  if (typeof raw !== "number" || !Number.isFinite(raw) || raw <= 0) return null;

  const ratio = BUDGET_BUMP_RATIOS[0];
  const next = Math.round(raw * ratio * 100) / 100;
  if (next <= raw) return null;

  const pctLabel = Math.round((ratio - 1) * 100);
  const priceLabel = prettyMoneyKwd(next);
  return {
    kind: "budget_bump",
    filters: { ...filters, maxPrice: next },
    headline_ar: `ارفع الميزانية إلى ${priceLabel} د.ك`,
    headline_en: `Raise budget to ${priceLabel} KWD`,
    detail_ar: `+${pctLabel}% على ميزانيتك الحالية`,
    detail_en: `+${pctLabel}% over your current cap`,
  };
}

// ---------------------------------------------------------------------------
// Strategy: area widen
// ---------------------------------------------------------------------------

function buildAreaWidenAlternative(
  filters: SuggestionFilters,
  nearbyAreaCodes: string[]
): SuggestionAlternative | null {
  if (!filters.areaCode) return null;
  const current = filters.areaCode.trim().toLowerCase();
  const cleaned = nearbyAreaCodes
    .map((x) => (typeof x === "string" ? x.trim().toLowerCase() : ""))
    .filter((x) => x.length > 0 && x !== current);
  if (cleaned.length === 0) return null;

  // Property-type gating. The client-provided neighbor list is generic;
  // applying it blindly suggests e.g. "رابية" for a chalet query, which
  // is logically impossible (Rabia is a residential area, no chalets).
  // If `propertyType` is recognized, we restrict the candidate set to
  // areas that make sense for that type. If the intersection is empty we
  // drop the strategy — "no suggestion" beats "wrong suggestion".
  const allow = allowedAreaCodesForPropertyType(filters.propertyType);
  let candidates: string[];
  if (allow) {
    const allowSet = new Set(allow.map((x) => x.toLowerCase()));
    candidates = cleaned.filter((x) => allowSet.has(x));
    if (candidates.length === 0) {
      // Extra-validation: try to graft an area directly from the allowlist
      // (minus the user's current area) as a last-resort widen target. This
      // ensures a chalet user whose current area has no valid neighbors in
      // the generic neighbor map still gets a coherent suggestion like
      // "try Khairan" rather than nothing — but ONLY when we have a
      // property-type allowlist to keep it domain-correct.
      candidates = allow
        .map((x) => x.toLowerCase())
        .filter((x) => x !== current);
      if (candidates.length === 0) return null;
    }
  } else {
    candidates = cleaned;
  }

  // Pick the first valid candidate as the primary alternative. The client's
  // existing nearby-search path still widens the scope across all neighbors;
  // this chip is a user-visible explanation plus an actionable patch.
  const firstNeighbor = candidates[0];
  return {
    kind: "area_widen",
    filters: { ...filters, areaCode: firstNeighbor },
    headline_ar: `وسّع البحث لمناطق مجاورة`,
    headline_en: `Widen to nearby areas`,
    detail_ar: `ابدأ بـ ${firstNeighbor}`,
    detail_en: `Starting with ${firstNeighbor}`,
  };
}

// ---------------------------------------------------------------------------
// Banner composition
// ---------------------------------------------------------------------------

function composeBanner(
  reason: FailureReason,
  alternatives: SuggestionAlternative[]
): { banner_ar: string; banner_en: string } {
  // If we produced no alternatives we still emit a soft banner so the caller
  // can decide to show or suppress it. Copy stays neutral.
  if (alternatives.length === 0 || reason === "none" || reason === "unknown") {
    return { banner_ar: "", banner_en: "" };
  }

  const shift = alternatives.find((a) => a.kind === "availability_shift");
  const budget = alternatives.find((a) => a.kind === "budget_bump");
  const area = alternatives.find((a) => a.kind === "area_widen");

  switch (reason) {
    case "availability": {
      if (shift) {
        return {
          banner_ar: `بهالتواريخ أغلب الشاليهات محجوزة، بس أقدر أطلع لك خيارات قريبة جداً ${shift.headline_ar.replace("جرّب ", "")} 👇`,
          banner_en: `Most chalets are booked in that window — I pulled close alternatives: ${shift.headline_en.toLowerCase()} 👇`,
        };
      }
      return {
        banner_ar: "بهالتواريخ السوق مشغول، جرّب أيام قريبة منها وخلني أشيك لك 👌",
        banner_en: "That window is crowded — try a day or two off, and I'll re-check for you.",
      };
    }
    case "budget": {
      if (budget) {
        return {
          banner_ar: `بميزانيتك الحالية الخيارات ضيقة، بس لو ${budget.headline_ar.toLowerCase()} يفتح لك خيارات حلوة 👇`,
          banner_en: `Your current budget is tight — if you ${budget.headline_en.toLowerCase()}, much better options open up 👇`,
        };
      }
      return {
        banner_ar: "بميزانيتك الحالية ما فيه شي قوي — قل لي الحد الأعلى المريح لك وأرتب لك أفضل ما متاح.",
        banner_en: "Nothing strong at your current budget — tell me a comfortable ceiling and I'll pull the best match.",
      };
    }
    case "area": {
      if (area) {
        return {
          banner_ar: `المنطقة مستهلكة حالياً، بس لو ${area.headline_ar} فيه خيارات قريبة بنفس المزايا 👇`,
          banner_en: `That area is thin right now — ${area.headline_en.toLowerCase()} and I'll show options with the same perks 👇`,
        };
      }
      return {
        banner_ar: "المنطقة مستهلكة حالياً، قل لي منطقة مجاورة مقبولة لك وأعطيك أفضل ما لقيت.",
        banner_en: "That area is thin right now — name a nearby area you'd accept and I'll surface the best options.",
      };
    }
    default:
      return { banner_ar: "", banner_en: "" };
  }
}

// ---------------------------------------------------------------------------
// Final domain-validation gate
// ---------------------------------------------------------------------------

/**
 * Defense-in-depth check applied to every alternative before it leaves the
 * server. Returns false for logically impossible combinations so the UI
 * never renders a broken suggestion.
 *
 * Current rules:
 *   1. `area_widen` alternatives must propose an `areaCode` compatible with
 *      the user's `propertyType` (e.g. no chalet-in-Rabia).
 *   2. The proposed `areaCode` must not equal the user's current one (the
 *      per-strategy builder already enforces this, but we re-check here
 *      so a new strategy that bypasses the builder can't regress).
 *
 * Add more rules here as new strategies appear. Intentionally silent — an
 * invalid alternative is dropped, not reported; the caller just sees one
 * less chip.
 */
function isAlternativeLogicallyValid(
  alt: SuggestionAlternative,
  base: SuggestionFilters
): boolean {
  if (alt.kind === "area_widen") {
    const proposed = (alt.filters.areaCode ?? "").trim().toLowerCase();
    if (!proposed) return false;
    const current = (base.areaCode ?? "").trim().toLowerCase();
    if (current && proposed === current) return false;

    const allow = allowedAreaCodesForPropertyType(base.propertyType);
    if (allow) {
      const allowSet = new Set(allow.map((x) => x.toLowerCase()));
      if (!allowSet.has(proposed)) return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// Public library entry point
// ---------------------------------------------------------------------------

export async function generateSmartSuggestions(
  input: GenerateSmartSuggestionsInput
): Promise<GenerateSmartSuggestionsOutput> {
  const filters = (input.filters ?? {}) as SuggestionFilters;
  const threshold = SMART_SUGGESTIONS_WEAK_THRESHOLD;
  const triggered =
    typeof input.originalResultCount === "number" &&
    input.originalResultCount < threshold;

  if (!triggered) {
    return {
      failureReason: "none",
      alternatives: [],
      banner_ar: "",
      banner_en: "",
      triggered: false,
    };
  }

  const candidatePool = Array.isArray(input.candidatePropertyIds)
    ? input.candidatePropertyIds
        .map((x) => (typeof x === "string" ? x.trim() : ""))
        .filter((x) => x.length > 0)
    : [];
  const nearbyAreaCodes = Array.isArray(input.nearbyAreaCodes)
    ? input.nearbyAreaCodes
        .map((x) => (typeof x === "string" ? x.trim() : ""))
        .filter((x) => x.length > 0)
    : [];

  // Execute strategies in the order that best reflects user intent. Order
  // also defines the default "failureReason" selection: the first strategy
  // that produced an alternative becomes the primary reason.
  const shiftAlt = await buildAvailabilityShiftAlternative(
    filters,
    candidatePool
  );
  const budgetAlt = buildBudgetBumpAlternative(filters);
  const areaAlt = buildAreaWidenAlternative(filters, nearbyAreaCodes);

  const ordered: SuggestionAlternative[] = [];
  if (shiftAlt) ordered.push(shiftAlt);
  if (areaAlt) ordered.push(areaAlt);
  if (budgetAlt) ordered.push(budgetAlt);

  // Final domain validation pass. Each strategy already validates its own
  // inputs, but we run one more check before we ship anything to the client
  // so a future strategy refactor cannot silently introduce a logically
  // invalid suggestion (e.g. "a chalet in Rabia").
  const ordered2 = ordered.filter((a) =>
    isAlternativeLogicallyValid(a, filters)
  );

  const cap = Math.max(
    1,
    Math.min(
      input.maxAlternatives ?? MAX_ALTERNATIVES,
      MAX_ALTERNATIVES
    )
  );
  const alternatives = ordered2.slice(0, cap);

  let failureReason: FailureReason = "unknown";
  if (alternatives[0]) {
    if (alternatives[0].kind === "availability_shift") failureReason = "availability";
    else if (alternatives[0].kind === "area_widen") failureReason = "area";
    else if (alternatives[0].kind === "budget_bump") failureReason = "budget";
  }

  const { banner_ar, banner_en } = composeBanner(failureReason, alternatives);

  return {
    failureReason,
    alternatives,
    banner_ar,
    banner_en,
    triggered: true,
  };
}

// ---------------------------------------------------------------------------
// Callable wrapper
// ---------------------------------------------------------------------------

/** Input hard limit for `candidatePropertyIds` on the callable. */
const SMART_SUGGESTIONS_MAX_IDS = 200;

export const generateChatSmartSuggestions = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required");
    }
    const data = (request.data as Record<string, unknown>) || {};
    const filtersRaw = (data.filters as Record<string, unknown>) || {};
    const filters: SuggestionFilters = {
      serviceType: typeof filtersRaw.serviceType === "string" ? filtersRaw.serviceType : undefined,
      propertyType: typeof filtersRaw.propertyType === "string" ? filtersRaw.propertyType : undefined,
      rentalType: typeof filtersRaw.rentalType === "string" ? filtersRaw.rentalType : undefined,
      areaCode: typeof filtersRaw.areaCode === "string" ? filtersRaw.areaCode : undefined,
      governorateCode: typeof filtersRaw.governorateCode === "string" ? filtersRaw.governorateCode : undefined,
      maxPrice: typeof filtersRaw.maxPrice === "number"
        ? filtersRaw.maxPrice
        : typeof filtersRaw.maxPrice === "string"
          ? Number(filtersRaw.maxPrice) || undefined
          : undefined,
      bedrooms: typeof filtersRaw.bedrooms === "number" ? filtersRaw.bedrooms : undefined,
      startDate: typeof filtersRaw.startDate === "string" ? filtersRaw.startDate : undefined,
      endDate: typeof filtersRaw.endDate === "string" ? filtersRaw.endDate : undefined,
      nights: typeof filtersRaw.nights === "number" ? filtersRaw.nights : undefined,
    };

    const originalResultCount =
      typeof data.originalResultCount === "number" && Number.isFinite(data.originalResultCount)
        ? data.originalResultCount
        : 0;

    const candidatePropertyIds = Array.isArray(data.candidatePropertyIds)
      ? (data.candidatePropertyIds as unknown[])
          .map((x) => (typeof x === "string" ? x.trim() : ""))
          .filter((x) => x.length > 0)
      : [];
    if (candidatePropertyIds.length > SMART_SUGGESTIONS_MAX_IDS) {
      throw new HttpsError(
        "invalid-argument",
        `Too many candidatePropertyIds (max ${SMART_SUGGESTIONS_MAX_IDS})`
      );
    }

    const nearbyAreaCodes = Array.isArray(data.nearbyAreaCodes)
      ? (data.nearbyAreaCodes as unknown[])
          .map((x) => (typeof x === "string" ? x.trim() : ""))
          .filter((x) => x.length > 0)
      : [];

    try {
      return await generateSmartSuggestions({
        filters,
        originalResultCount,
        candidatePropertyIds,
        nearbyAreaCodes,
      });
    } catch (err) {
      console.error({
        tag: "generateChatSmartSuggestions.error",
        message: err instanceof Error ? err.message : String(err),
      });
      throw new HttpsError("internal", "Smart suggestions failed");
    }
  }
);
