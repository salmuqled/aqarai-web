/**
 * Single source of truth for conversation search state.
 * Maps client filters (type -> propertyType) and exposes query filters (propertyType -> type).
 */

export type ConversationStage = "initial" | "refinement" | "comparison" | "clarification";

export type BuyerIntent = "residential" | "investment";

export interface SearchContext {
  areaCode?: string;
  propertyType?: string;
  serviceType?: string;
  budget?: number;
  bedrooms?: number;

  minArea?: number;
  maxArea?: number;

  investmentFlag?: boolean;
  preferredNearbyAreas?: string[];

  intent?: BuyerIntent;
  lastModifier?: string;
  conversationStage?: ConversationStage;
}

export function createEmptySearchContext(): SearchContext {
  return {};
}

/** Build SearchContext from client currentFilters (type maps to propertyType). */
export function getSearchContextFromFilters(filters: Record<string, unknown>): SearchContext {
  const ctx: SearchContext = {};
  const areaCode = filters.areaCode;
  if (areaCode != null && String(areaCode).trim() !== "") ctx.areaCode = String(areaCode).trim();
  const type = filters.type;
  if (type != null && String(type).trim() !== "") ctx.propertyType = String(type).trim();
  const serviceType = filters.serviceType;
  if (serviceType != null && String(serviceType).trim() !== "") ctx.serviceType = String(serviceType).trim();
  const budget = filters.budget;
  if (budget != null && typeof budget === "number" && !Number.isNaN(budget)) ctx.budget = budget;
  const bedrooms = filters.bedrooms;
  if (bedrooms != null && typeof bedrooms === "number" && !Number.isNaN(bedrooms)) ctx.bedrooms = bedrooms;
  return ctx;
}

/** Build query filters (params_patch shape) from SearchContext; propertyType -> type for client. Only defined fields. */
export function contextToQueryFilters(context: SearchContext): Record<string, unknown> {
  const q: Record<string, unknown> = {};
  if (context.areaCode != null && context.areaCode !== "") q.areaCode = context.areaCode;
  if (context.propertyType != null && context.propertyType !== "") q.type = context.propertyType;
  if (context.serviceType != null && context.serviceType !== "") q.serviceType = context.serviceType;
  if (context.budget != null && !Number.isNaN(Number(context.budget))) q.budget = context.budget;
  if (context.bedrooms != null && !Number.isNaN(Number(context.bedrooms))) q.bedrooms = context.bedrooms;
  return q;
}
