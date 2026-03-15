/**
 * Convert SearchContext into Firestore query filters only. No ranking, no text.
 */
import type { SearchContext } from "./search_context";

export interface BuiltQueryPlan {
  areaCode?: string;
  type?: string;
  serviceType?: string;
  budget?: number;
  bedrooms?: number;
}

export function buildQueryPlan(context: SearchContext): BuiltQueryPlan {
  const plan: BuiltQueryPlan = {};
  if (context.areaCode != null && context.areaCode !== "") plan.areaCode = context.areaCode;
  if (context.propertyType != null && context.propertyType !== "") plan.type = context.propertyType;
  if (context.serviceType != null && context.serviceType !== "") plan.serviceType = context.serviceType;
  if (context.budget != null && !Number.isNaN(Number(context.budget))) plan.budget = context.budget;
  if (context.bedrooms != null && !Number.isNaN(Number(context.bedrooms))) plan.bedrooms = context.bedrooms;
  return plan;
}
