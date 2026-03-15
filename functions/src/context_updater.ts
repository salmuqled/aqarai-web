/**
 * Pure SearchContext mutation. No Firestore, no I/O.
 */
import type { SearchContext } from "./search_context";
import { createEmptySearchContext } from "./search_context";
import type { ParsedIntentResult } from "./intent_parser";

/** Apply params patch onto context; new values override. Returns new context. */
export function applyParamsToContext(
  context: SearchContext,
  paramsPatch: Record<string, unknown>
): SearchContext {
  const next: SearchContext = { ...context };
  const areaCode = paramsPatch.areaCode;
  if (areaCode != null && String(areaCode).trim() !== "") next.areaCode = String(areaCode).trim();
  const type = paramsPatch.type;
  if (type != null && String(type).trim() !== "") next.propertyType = String(type).trim();
  const serviceType = paramsPatch.serviceType;
  if (serviceType != null && String(serviceType).trim() !== "") next.serviceType = String(serviceType).trim();
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
