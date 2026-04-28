/**
 * Single source of truth for conversation search state.
 * Maps client filters (type -> propertyType) and exposes query filters (propertyType -> type).
 */

export type ConversationStage = "initial" | "refinement" | "comparison" | "clarification";

export type BuyerIntent = "residential" | "investment";

export interface SearchContext {
  areaCode?: string;
  /**
   * Multi-area selection — populated when the customer named 2+ distinct
   * `areaCode`s in one breath ("الخيران بنيدر جليعه") OR when the orchestrator
   * expanded a vague chalet request to the canonical chalet belt.
   *
   * When set, the search service runs a Firestore `whereIn` over this list
   * (each entry already canonical, no fabricated concatenated slugs). Always
   * an array of distinct lowercase canonical slugs; we keep [areaCode]
   * populated alongside it (= first entry) so legacy single-area consumers
   * still work without changes.
   */
  areaCodes?: string[];
  propertyType?: string;
  serviceType?: string;
  /** `daily` | `monthly` | `full` — optional rental cadence for rent listings. */
  rentalType?: string;
  budget?: number;
  bedrooms?: number;

  minArea?: number;
  maxArea?: number;

  investmentFlag?: boolean;
  preferredNearbyAreas?: string[];

  intent?: BuyerIntent;
  lastModifier?: string;
  conversationStage?: ConversationStage;

  // Date Intelligence Layer — hotel convention: endDate is exclusive check-out.
  // All three fields MUST be set together (parser enforces). Stored as ISO-8601
  // UTC midnight strings to survive JSON transport between Functions and Flutter.
  /** Inclusive check-in day, ISO-8601 UTC midnight. */
  startDate?: string;
  /** Exclusive check-out day, ISO-8601 UTC midnight. */
  endDate?: string;
  /** Whole nights (endDate - startDate). Always >= 1 when present. */
  nights?: number;
}

export function createEmptySearchContext(): SearchContext {
  return {};
}

/**
 * Coerce any raw date-ish input (ISO string, millis number, Firestore Timestamp
 * POJO with `seconds`, Date) into an ISO-8601 UTC midnight string. Returns null
 * on any parse failure or empty input — callers MUST treat null as "absent".
 */
export function coerceDateToIsoUtc(value: unknown): string | null {
  if (value == null || value === "") return null;
  if (value instanceof Date) {
    if (Number.isNaN(value.getTime())) return null;
    return value.toISOString();
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return null;
    return new Date(value).toISOString();
  }
  if (typeof value === "string") {
    const ms = Date.parse(value);
    if (Number.isNaN(ms)) return null;
    return new Date(ms).toISOString();
  }
  if (typeof value === "object") {
    const rec = value as { seconds?: unknown; _seconds?: unknown };
    const s = rec.seconds ?? rec._seconds;
    if (typeof s === "number" && Number.isFinite(s)) {
      return new Date(s * 1000).toISOString();
    }
  }
  return null;
}

/** Build SearchContext from client currentFilters (type maps to propertyType). */
export function getSearchContextFromFilters(filters: Record<string, unknown>): SearchContext {
  const ctx: SearchContext = {};
  const areaCode = filters.areaCode;
  if (areaCode != null && String(areaCode).trim() !== "") ctx.areaCode = String(areaCode).trim();
  const areaCodesRaw = filters.areaCodes;
  if (Array.isArray(areaCodesRaw)) {
    const codes = areaCodesRaw
      .map((v) => (typeof v === "string" ? v.trim().toLowerCase() : ""))
      .filter((v) => v.length > 0);
    const distinct = Array.from(new Set(codes));
    if (distinct.length >= 2) ctx.areaCodes = distinct;
  }
  const type = filters.type;
  if (type != null && String(type).trim() !== "") ctx.propertyType = String(type).trim();
  const serviceType = filters.serviceType;
  if (serviceType != null && String(serviceType).trim() !== "") ctx.serviceType = String(serviceType).trim();
  const rentalType = filters.rentalType;
  if (rentalType != null) {
    const rt = String(rentalType).trim().toLowerCase();
    if (rt === "daily" || rt === "monthly" || rt === "full") ctx.rentalType = rt;
  }
  const budget = filters.budget;
  if (budget != null && typeof budget === "number" && !Number.isNaN(budget)) ctx.budget = budget;
  const bedrooms = filters.bedrooms;
  if (bedrooms != null && typeof bedrooms === "number" && !Number.isNaN(bedrooms)) ctx.bedrooms = bedrooms;

  const start = coerceDateToIsoUtc(filters.startDate);
  const end = coerceDateToIsoUtc(filters.endDate);
  if (start && end) {
    const diffMs = Date.parse(end) - Date.parse(start);
    const nights = Math.round(diffMs / 86_400_000);
    if (nights >= 1 && nights <= 365) {
      ctx.startDate = start;
      ctx.endDate = end;
      const rawNights = filters.nights;
      const parsedNights =
        typeof rawNights === "number" && Number.isFinite(rawNights)
          ? Math.round(rawNights)
          : nights;
      ctx.nights = parsedNights > 0 ? parsedNights : nights;
    }
  }
  return ctx;
}

/** Build query filters (params_patch shape) from SearchContext; propertyType -> type for client. Only defined fields. */
export function contextToQueryFilters(context: SearchContext): Record<string, unknown> {
  const q: Record<string, unknown> = {};
  if (context.areaCode != null && context.areaCode !== "") q.areaCode = context.areaCode;
  if (Array.isArray(context.areaCodes) && context.areaCodes.length >= 2) {
    q.areaCodes = context.areaCodes.slice();
  }
  if (context.propertyType != null && context.propertyType !== "") q.type = context.propertyType;
  if (context.serviceType != null && context.serviceType !== "") q.serviceType = context.serviceType;
  if (context.rentalType != null && context.rentalType !== "") q.rentalType = context.rentalType;
  if (context.budget != null && !Number.isNaN(Number(context.budget))) q.budget = context.budget;
  if (context.bedrooms != null && !Number.isNaN(Number(context.bedrooms))) q.bedrooms = context.bedrooms;
  // Date Intelligence: only propagate when the full triple is present and consistent.
  if (
    context.startDate != null &&
    context.endDate != null &&
    context.nights != null &&
    context.nights > 0
  ) {
    q.startDate = context.startDate;
    q.endDate = context.endDate;
    q.nights = context.nights;
  }
  return q;
}
