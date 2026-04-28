/**
 * Pure SearchContext mutation. No Firestore, no I/O.
 */
import type { SearchContext } from "./search_context";
import { createEmptySearchContext, coerceDateToIsoUtc } from "./search_context";
import type { ParsedIntentResult } from "./intent_parser";

/** Apply params patch onto context; new values override. Returns new context. */
export function applyParamsToContext(
  context: SearchContext,
  paramsPatch: Record<string, unknown>
): SearchContext {
  const next: SearchContext = { ...context };
  const areaCode = paramsPatch.areaCode;
  const newAreaCodeSet =
    areaCode != null && String(areaCode).trim() !== "";
  if (newAreaCodeSet) next.areaCode = String(areaCode).trim();
  // Multi-area patch: replace the previous selection (don't merge) when this
  // turn provides a fresh list. An explicit empty array is treated as "clear",
  // which is what `isNewSearch` flows want when the customer pivots.
  const areaCodes = paramsPatch.areaCodes;
  if (Array.isArray(areaCodes)) {
    const distinct = Array.from(
      new Set(
        areaCodes
          .map((v) => (typeof v === "string" ? v.trim().toLowerCase() : ""))
          .filter((v) => v.length > 0)
      )
    );
    if (distinct.length >= 2) {
      next.areaCodes = distinct;
    } else {
      delete next.areaCodes;
    }
  } else if (newAreaCodeSet) {
    // Customer narrowed from a multi-area browse to a single area
    // ("خلاص بس الخيران"). Drop the inherited list so downstream queries
    // run a single-area search and don't keep showing other belt areas.
    delete next.areaCodes;
  }
  const type = paramsPatch.type;
  if (type != null && String(type).trim() !== "") next.propertyType = String(type).trim();
  const serviceType = paramsPatch.serviceType;
  if (serviceType != null && String(serviceType).trim() !== "") next.serviceType = String(serviceType).trim();
  const rentalType = paramsPatch.rentalType;
  if (rentalType != null) {
    const rt = String(rentalType).trim().toLowerCase();
    if (rt === "daily" || rt === "monthly" || rt === "full") next.rentalType = rt;
  }
  const budget = paramsPatch.budget;
  if (budget != null && (typeof budget === "number" || typeof budget === "string")) {
    const n = typeof budget === "number" ? budget : Number(budget);
    if (!Number.isNaN(n)) next.budget = n;
  }
  const bedrooms = paramsPatch.bedrooms;
  if (bedrooms != null && (typeof bedrooms === "number" || typeof bedrooms === "string")) {
    const n = typeof bedrooms === "number" ? bedrooms : Number(bedrooms);
    if (!Number.isNaN(n)) next.bedrooms = n;
  }

  // Date Intelligence Layer — only accept when both start/end are parseable AND
  // end is strictly after start. A partial patch (start without end, or vice
  // versa) is ignored to preserve the "do not assume" contract from the parser.
  const start = coerceDateToIsoUtc(paramsPatch.startDate);
  const end = coerceDateToIsoUtc(paramsPatch.endDate);
  if (start && end) {
    const diffMs = Date.parse(end) - Date.parse(start);
    const nights = Math.round(diffMs / 86_400_000);
    if (nights >= 1 && nights <= 365) {
      next.startDate = start;
      next.endDate = end;
      const rawNights = paramsPatch.nights;
      const parsedNights =
        typeof rawNights === "number" && Number.isFinite(rawNights)
          ? Math.round(rawNights)
          : typeof rawNights === "string" && rawNights !== ""
            ? Math.round(Number(rawNights))
            : nights;
      next.nights = Number.isFinite(parsedNights) && parsedNights > 0
        ? parsedNights
        : nights;
    }
  }
  return next;
}

/** Apply modifier (أرخص شوي، أكبر شوي, etc.) to context. Returns new context. */
export function applyModifierToContext(
  context: SearchContext,
  modifier: { type: string } | null
): SearchContext {
  if (!modifier) return { ...context };
  const next: SearchContext = {
    ...context,
    lastModifier: modifier.type,
    conversationStage: "refinement",
  };
  if (modifier.type === "budget_down" && context.budget != null) {
    next.budget = Math.round(Number(context.budget) * 0.9);
  } else if (modifier.type === "budget_up" && context.budget != null) {
    next.budget = Math.round(Number(context.budget) * 1.1);
  } else if (modifier.type === "size_up") {
    next.bedrooms = (context.bedrooms ?? 3) + 1;
  } else if (modifier.type === "size_down") {
    next.bedrooms = Math.max(1, (context.bedrooms ?? 3) - 1);
  }
  return next;
}

/** Merge previous context with parsed intent for this turn. New search -> start empty; else apply params then modifier. */
export function mergeContextForTurn(
  previous: SearchContext,
  parsed: ParsedIntentResult
): SearchContext {
  let context: SearchContext;
  if (parsed.isNewSearch) {
    context = createEmptySearchContext();
  } else {
    context = { ...previous };
  }
  context = applyParamsToContext(context, parsed.paramsPatch);
  if (parsed.modifier) {
    context = applyModifierToContext(context, parsed.modifier);
  }
  if (parsed.isNewSearch) {
    context.conversationStage = "initial";
  } else if (parsed.modifier && !context.conversationStage) {
    context.conversationStage = "refinement";
  }
  if (parsed.buyerIntent) context.intent = parsed.buyerIntent;
  return context;
}
