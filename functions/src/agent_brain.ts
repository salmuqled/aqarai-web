/**
 * AI Agent Brain: AI Real Estate Agent (From Bot to Agent)
 *
 * Context policy (received from client):
 *   - last8Messages: last 8 chat messages (role + content)
 *   - currentFilters: areaCode, type, serviceType, budget, bedrooms
 *   - top3LastResults: [{ id, areaAr, areaEn, type, price, size }]
 *
 * aqaraiAgentAnalyze: message + context -> STRICT JSON
 *   { intent, params_patch, reset_filters, is_complete, clarifying_questions }
 *   - intent: search_property | greeting | follow_up | general_question
 *   - params_patch: only non-null keys (areaCode, type, serviceType, budget, bedrooms, investmentFlag)
 *   - Never hallucinate numbers; areaCode required for search
 *
 * aqaraiAgentCompose: top3 results -> marketing reply (1-3 options, ONE next question, Kuwaiti tone)
 *
 * Step tests: a) السلام عليكم b) ابي بيت للبيع بالقادسية c) ابي أرخص d) كم غرفة؟ e) غير المنطقة للنزهة
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import OpenAI from "openai";
import { normalizeAreaName } from "./area_normalizer";

const db = admin.firestore();

// ---------------------------------------------------------------------------
// In-memory search cache (60s TTL; reduces latency for repeated queries)
// ---------------------------------------------------------------------------

const SEARCH_CACHE = new Map<string, { data: unknown; timestamp: number }>();
const CACHE_TTL_MS = 60000; // 60 seconds

function getCacheKey(params: { areaCode?: string; type?: string; serviceType?: string; budget?: number | null }): string {
  return JSON.stringify({
    areaCode: params.areaCode ?? "",
    type: params.type ?? "",
    serviceType: params.serviceType ?? "",
    budget: params.budget ?? null,
  });
}

function getCachedResult(key: string): unknown | null {
  const entry = SEARCH_CACHE.get(key);
  if (!entry) return null;

  const now = Date.now();
  if (now - entry.timestamp > CACHE_TTL_MS) {
    SEARCH_CACHE.delete(key);
    return null;
  }

  return entry.data;
}

function setCachedResult(key: string, data: unknown): void {
  SEARCH_CACHE.set(key, {
    data,
    timestamp: Date.now(),
  });
}

// ---------------------------------------------------------------------------
// Arabic text normalization (for keyword matching)
// ---------------------------------------------------------------------------

/**
 * Normalize Arabic letters and remove tashkeel so different spellings match.
 * - أ / إ / آ → ا
 * - ة → ه
 * - ى → ي
 * - Remove diacritics (tashkeel)
 */
export function normalizeArabic(text: string): string {
  if (!text || typeof text !== "string") return "";
  let s = text
    .replace(/[\u0622\u0623\u0625]/g, "\u0627")
    .replace(/\u0629/g, "\u0647")
    .replace(/\u0649/g, "\u064A")
    .replace(/[\u064B-\u0652\u0670]/g, "");
  return s;
}

// ---------------------------------------------------------------------------
// Kuwaiti Arabic intent normalization (before search)
// ---------------------------------------------------------------------------

export interface KuwaitiIntentNormalized {
  propertyType?: string;
  serviceType?: string;
  requestType?: string;
  /** Optional metadata: e.g. "corner", "double_street" (not in Firestore schema) */
  features?: string[];
  /** Optional metadata: e.g. 2 for "دورين" (not in Firestore schema) */
  floors?: number;
  normalizedText: string;
}

/** Phrases that map to serviceType (order: longer matches first; substring match for Arabic) */
const SERVICE_PHRASES: { phrases: string[]; value: string }[] = [
  { phrases: ["بدلية", "بدليه", "بدل"], value: "exchange" },
  { phrases: ["للإيجار", "للايجار", "إيجار", "ايجار"], value: "rent" },
  { phrases: ["للبيع", "بيع"], value: "sale" },
];

/** Phrases that map to propertyType (order: longer/more specific first) */
const PROPERTY_PHRASES: { phrases: string[]; value: string }[] = [
  { phrases: ["شاليهات", "شاليه"], value: "chalet" },
  { phrases: ["منزل", "بيت", "سكني"], value: "house" },
  { phrases: ["شقة", "شقه"], value: "apartment" },
  { phrases: ["أرض", "ارض"], value: "land" },
  { phrases: ["بناية", "بنايه", "عمارة", "عماره", "استثماري"], value: "building" },
  { phrases: ["فيلا", "فيله"], value: "villa" },
  { phrases: ["مكتب"], value: "office" },
  { phrases: ["تجاري"], value: "commercial" },
  { phrases: ["مخزن"], value: "warehouse" },
  { phrases: ["محل"], value: "shop" },
];

/** Phrases that map to requestType */
const REQUEST_PHRASES: { phrases: string[]; value: string }[] = [
  { phrases: ["مطلوب"], value: "wanted" },
];

/** Property features (optional metadata; not stored in Firestore) */
const FEATURE_PHRASES: { phrases: string[]; value: string }[] = [
  { phrases: ["زاوية", "زاويه"], value: "corner" },
  { phrases: ["بطن وظهر", "بطن و ظهر"], value: "double_street" },
];

/** Floors (optional metadata; e.g. "دورين" -> 2) */
const FLOORS_PHRASES: { phrases: string[]; value: number }[] = [
  { phrases: ["دورين"], value: 2 },
];

/**
 * Detect and normalize common Kuwaiti / Gulf real-estate phrases in the user message.
 * Uses normalizeArabic(text) before matching so different spellings (إيجار, ايجار) match.
 * Returns normalized propertyType, serviceType, requestType, optional features/floors; does not change area logic.
 */
export function normalizeKuwaitiIntent(text: string): KuwaitiIntentNormalized {
  const t = (text || "").trim();
  const tNorm = normalizeArabic(t);
  let propertyType: string | undefined;
  let serviceType: string | undefined;
  let requestType: string | undefined;
  const features: string[] = [];
  let floors: number | undefined;

  for (const { phrases, value } of SERVICE_PHRASES) {
    if (phrases.some((p) => tNorm.includes(normalizeArabic(p)))) {
      serviceType = value;
      break;
    }
  }
  for (const { phrases, value } of PROPERTY_PHRASES) {
    if (phrases.some((p) => tNorm.includes(normalizeArabic(p)))) {
      propertyType = value;
      break;
    }
  }
  for (const { phrases, value } of REQUEST_PHRASES) {
    if (phrases.some((p) => tNorm.includes(normalizeArabic(p)))) {
      requestType = value;
      break;
    }
  }
  for (const { phrases, value } of FEATURE_PHRASES) {
    if (phrases.some((p) => tNorm.includes(normalizeArabic(p)))) {
      features.push(value);
    }
  }
  for (const { phrases, value } of FLOORS_PHRASES) {
    if (phrases.some((p) => tNorm.includes(normalizeArabic(p)))) {
      floors = value;
      break;
    }
  }

  const out: KuwaitiIntentNormalized = {
    propertyType,
    serviceType,
    requestType,
    normalizedText: t,
  };
  if (features.length > 0) out.features = features;
  if (floors != null) out.floors = floors;
  return out;
}

const ANALYZE_SYSTEM = `You are a Kuwaiti real estate expert. Mode: SEARCH FIRST — ASK LATER. Extract whatever the user provides and allow search immediately. Return JSON only.

Normalize Arabic to DB keys:
- Areas: القادسية->qadisiya, النزهة->nuzha, السالمية->salmiya, الدسمة->dasma, الشامية->shamiya, الخالدية->khaldiya, كيفان->kaifan, الجابرية->jabriya, الفروانية->farwaniya, حولي->hawalli, الأحمدي->ahmadi, الجهراء->jahra, مبارك الكبير->mubarak_al_kabeer (lowercase, underscores for spaces).
- Property types: بيت/قسيمة/دار->house, شقة->apartment, فيلا->villa, شاليه->chalet, أرض->land, مكتب->office, محل->shop.
- Budget: "حدود 700 ألف" / "700 الف" -> 700000, "500 ألف" -> 500000. Never invent numbers; only from message or currentFilters.

SEARCH FIRST — ASK LATER:
1. From the user message, extract ALL available: areaCode, type, serviceType, budget, bedrooms.
2. Set is_complete=true whenever you have an area (areaCode). Run search with whatever you have; missing type/budget/rooms is OK. The client will search immediately.
3. Only set is_complete=false when area is missing. Then add exactly ONE short Arabic question in clarifying_questions (e.g. "في أي منطقة تبحث؟"). NEVER ask a sequence (area? then type? then budget?). One question only.
4. If user says "ابي بيت بالقادسية حدود 700 ألف": set areaCode=qadisiya, type=house, budget=700000, serviceType=sale (default), is_complete=true. No clarifying_questions.
5. Follow-ups: "أرخص" -> params_patch.budget = current*0.9; "أكبر" -> size note; "غير المنطقة للنزهة" -> reset_filters=true, params_patch.areaCode=nuzha.
6. For house: do not ask about bedrooms. For apartment: you may ask bedrooms. When asking, always ONE question only.

Output ONLY valid JSON (no markdown, no \`\`\`):
{
  "intent": "search_property | greeting | follow_up | general_question",
  "params_patch": {
    "areaCode": "string|null",
    "type": "house|apartment|villa|chalet|land|office|shop|null",
    "serviceType": "sale|rent|exchange|null",
    "budget": number|null,
    "bedrooms": number|null,
    "investmentFlag": boolean|null
  },
  "reset_filters": boolean,
  "is_complete": boolean,
  "clarifying_questions": ["single question or empty array"]
}

Rules:
- Greeting (سلام/هلا) with no search -> intent=greeting, is_complete=false, clarifying_questions can be empty.
- If area can be inferred from message or currentFilters -> is_complete=true, fill params_patch, clarifying_questions=[].
- If area is missing -> is_complete=false, clarifying_questions=["في أي منطقة تبحث؟"] (one question only).
- Never invent numbers. Merge with currentFilters on client. reset_filters only for "غير المنطقة" / change area.`;

const NO_RESULTS_AR = `حالياً ما لقيت عقار مطابق في هذه المنطقة.
أقدر:

1. أبحث في مناطق قريبة
2. أعرض كل العقارات المتوفرة
3. أسجلك كمهتم وأرسل لك إشعار إذا نزل إعلان جديد.`;

const NO_RESULTS_EN = `No matching property in this area right now.
I can:

1. Search nearby areas
2. Show all available properties
3. Register your interest and notify you when a new listing appears.`;

const SINGLE_RESULT_ASKED_MORE_AR =
  "حالياً هذا العقار الوحيد المطابق لطلبك في هذه المنطقة.\nإذا حاب أبحث لك في مناطق قريبة ممكن تناسبك.";
const SINGLE_RESULT_ASKED_MORE_EN =
  "This is currently the only property matching your request in this area.\nI can also check nearby areas if you'd like.";

const TYPE_LABEL_AR: Record<string, string> = {
  house: "بيت",
  apartment: "شقة",
  villa: "فيلا",
  chalet: "شاليه",
  land: "أرض",
  office: "مكتب",
  shop: "محل",
  building: "عمارة",
  industrialLand: "أرض صناعية",
};

function formatNearbyReplyAr(results: unknown[], requestedAreaLabel: string): string {
  const areaLabel = requestedAreaLabel || "هذه المنطقة";
  let intro = `حالياً ما لقيت عقار مطابق في ${areaLabel}،\nلكن لقيت عقارات قريبة ممكن تناسبك:\n\n`;
  const lines = (results as Record<string, unknown>[]).map((r) => {
    const type = (r.type as string) || "";
    const typeLabel = TYPE_LABEL_AR[type] || type;
    const area = (r.areaAr as string) || (r.areaEn as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    const priceStr = price >= 1000 ? `${Math.round(price / 1000)} ألف` : String(price);
    return `• ${typeLabel} في ${area} – السعر ${priceStr}`;
  });
  return intro + lines.join("\n");
}

function formatNearbyReplyEn(results: unknown[], requestedAreaLabel: string): string {
  const areaLabel = requestedAreaLabel || "this area";
  let intro = `No matching property in ${areaLabel} right now.\nFound nearby options that might work:\n\n`;
  const lines = (results as Record<string, unknown>[]).map((r) => {
    const type = (r.type as string) || "";
    const area = (r.areaEn as string) || (r.areaAr as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    return `• ${type} in ${area} – KWD ${price}`;
  });
  return intro + lines.join("\n");
}

// ---------------------------------------------------------------------------
// Suggestion Engine (next actions; no Firestore)
// ---------------------------------------------------------------------------

export interface SuggestionContext {
  areaCode?: string;
  propertyType?: string;
  serviceType?: string;
  userBudget?: number;
  resultsCount: number;
}

const SUGGESTIONS_HAVE_RESULTS_AR = [
  "تبي أشوف لك خيارات أرخص في نفس المنطقة؟",
  "تبي نفس النوع لكن في مناطق قريبة؟",
  "تبي نفس العقار للإيجار بدل الشراء؟",
];

const SUGGESTIONS_HAVE_RESULTS_EN = [
  "Want to see cheaper options in the same area?",
  "Want the same type in nearby areas?",
  "Want the same property for rent instead of sale?",
];

const SUGGESTIONS_NO_RESULTS_AR = [
  "تبي أشوف لك نفس العقار في مناطق قريبة؟",
  "تبي أوسع نطاق البحث؟",
  "تبي أبحث عن عقارات مشابهة؟",
];

const SUGGESTIONS_NO_RESULTS_EN = [
  "Want to see the same property in nearby areas?",
  "Want to widen the search scope?",
  "Want to search for similar properties?",
];

/** Generate up to 3 short next-action suggestions based on context. */
export function buildNextSuggestions(context: SuggestionContext, locale: "ar" | "en"): string[] {
  const count = context.resultsCount ?? 0;
  const list = count > 0
    ? (locale === "ar" ? SUGGESTIONS_HAVE_RESULTS_AR : SUGGESTIONS_HAVE_RESULTS_EN)
    : (locale === "ar" ? SUGGESTIONS_NO_RESULTS_AR : SUGGESTIONS_NO_RESULTS_EN);
  return list.slice(0, 3);
}

function appendSuggestionsToReply(reply: string, context: SuggestionContext, locale: "ar" | "en"): string {
  const suggestions = buildNextSuggestions(context, locale);
  if (suggestions.length === 0) return reply;
  const prefix = locale === "ar" ? "ممكن أيضاً:\n\n" : "You can also:\n\n";
  const lines = suggestions.map((s) => `• ${s}`).join("\n");
  return reply + "\n\n" + prefix + lines;
}

const COMPOSE_SYSTEM_AR = `You are a proactive Kuwaiti real estate broker. Smart Search Mode: fast, helpful, show results directly.

STRICT — NO HALLUCINATION: Only describe properties that exist in the provided search results. No invented addresses, prices, or details.

Format:
1. Open with a short line that you found options (e.g. "لقيت لك 3 عقارات ممكن تناسبك في القادسية:").
2. List each property from the results in one line with bullet (•): type, size if available, brief detail, price in د.ك (e.g. "• بيت 400م شارع واحد – السعر 680 ألف").
3. End with exactly ONE short follow-up question. Examples: "تبي أشوف لك تفاصيل واحد منهم؟" or "ميزانيتك تقريباً كم؟" or "تفضل شارع واحد أو زاوية؟". For house: do NOT ask about bedrooms; ask budget, land size, age, or street type. For apartment: you may ask bedrooms or budget.
Never ask more than one question. Be direct and broker-like.`;

const COMPOSE_SYSTEM_EN = `You are a proactive Kuwaiti real estate broker. Smart Search Mode: fast, helpful, show results directly.

STRICT — NO HALLUCINATION: Only describe properties that exist in the provided search results. No invented addresses, prices, or details.

Format:
1. Open with a short line that you found options (e.g. "Found 3 properties that might work for you in Qadisiya:").
2. List each property from the results in one line with bullet (•): type, size if available, brief detail, price in KWD.
3. End with exactly ONE short follow-up question (e.g. "Want details on one of them?" or "What's your budget?" or "Corner or single street?"). For house: do not ask about bedrooms. For apartment: you may ask bedrooms or budget.
Never ask more than one question. Be direct and broker-like.`;

function extractJson(text: string): Record<string, unknown> {
  const trimmed = text.trim();
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) {
    throw new Error("No JSON object in response");
  }
  const jsonStr = trimmed.substring(start, end + 1);
  return JSON.parse(jsonStr) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Market Awareness (buyer_interests + properties; no schema change)
// ---------------------------------------------------------------------------

/** Demand: count buyer_interests in last 7 days for areaCode + propertyType. buyer_interests uses "type" field. */
async function getMarketDemandStats(
  areaCode: string,
  propertyType: string
): Promise<{ demandLast7Days: number }> {
  if (!areaCode?.trim() || !propertyType?.trim()) return { demandLast7Days: 0 };
  const sevenDaysAgo = new Date();
  sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
  const q = db
    .collection("buyer_interests")
    .where("areaCode", "==", areaCode.trim())
    .where("type", "==", propertyType.trim())
    .where("createdAt", ">=", sevenDaysAgo);
  const snap = await q.get();
  return { demandLast7Days: snap.size };
}

/** Supply: count active properties for areaCode + type. */
async function getMarketSupplyStats(
  areaCode: string,
  propertyType: string
): Promise<{ supplyCount: number }> {
  if (!areaCode?.trim() || !propertyType?.trim()) return { supplyCount: 0 };
  const q = db
    .collection("properties")
    .where("areaCode", "==", areaCode.trim())
    .where("type", "==", propertyType.trim())
    .where("status", "==", "active");
  const snap = await q.get();
  return { supplyCount: snap.size };
}

type MarketSignal = "high_demand_low_supply" | "high_demand" | "low_demand" | "normal";

function analyzeMarket(demand: number, supply: number): MarketSignal {
  if (demand >= 10 && supply <= 3) return "high_demand_low_supply";
  if (demand >= 10 && supply > 10) return "high_demand";
  if (demand <= 3 && supply >= 10) return "low_demand";
  return "normal";
}

const MARKET_INSIGHT_AR: Record<MarketSignal, string> = {
  high_demand_low_supply: "حالياً الطلب على هذا النوع من العقارات في {area} مرتفع والعروض قليلة.",
  high_demand: "فيه طلب ملحوظ حالياً على هذا النوع من العقارات في {area}.",
  low_demand: "حالياً الطلب منخفض نسبياً على هذا النوع من العقارات في {area}.",
  normal: "",
};

const MARKET_INSIGHT_EN: Record<MarketSignal, string> = {
  high_demand_low_supply: "Demand for this type of property in {area} is high right now and supply is low.",
  high_demand: "There is noticeable demand for this type of property in {area} at the moment.",
  low_demand: "Demand for this type of property in {area} is relatively low at the moment.",
  normal: "",
};

function getMarketInsightText(signal: MarketSignal, areaLabel: string, locale: "ar" | "en"): string {
  if (signal === "normal") return "";
  const template = locale === "ar" ? MARKET_INSIGHT_AR[signal] : MARKET_INSIGHT_EN[signal];
  return template.replace("{area}", areaLabel || (locale === "ar" ? "هذه المنطقة" : "this area"));
}

// ---------------------------------------------------------------------------
// Smart Property Ranking (in-memory only; do not write to Firestore)
// ---------------------------------------------------------------------------

/** Get time in ms from Firestore Timestamp, ISO string, or ms number */
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

// ---------------------------------------------------------------------------
// Property Intelligence Labels (in-memory only; do not write to Firestore)
// ---------------------------------------------------------------------------

export type PropertyLabelId = "new_listing" | "high_demand" | "good_deal";

/**
 * Compute up to 2 labels per property from available fields and market signal.
 * - new_listing: createdAt within last 7 days
 * - high_demand: marketSignal === "high_demand_low_supply"
 * - good_deal: price < averagePriceSameArea (when average provided)
 */
export function computePropertyLabels(
  property: Record<string, unknown>,
  marketSignal: string,
  nowMs: number,
  averagePriceSameArea?: number | null
): PropertyLabelId[] {
  const labels: PropertyLabelId[] = [];
  const createdAt = toMillis(property.createdAt);
  if (createdAt != null && nowMs - createdAt <= 7 * 24 * 60 * 60 * 1000) {
    labels.push("new_listing");
  }
  if (marketSignal === "high_demand_low_supply") {
    labels.push("high_demand");
  }
  if (averagePriceSameArea != null && averagePriceSameArea > 0) {
    const price = typeof property.price === "number" ? property.price : Number(property.price);
    if (!Number.isNaN(price) && price < averagePriceSameArea) {
      labels.push("good_deal");
    }
  }
  return labels.slice(0, 2);
}

/** Score a single property; score is stored only in memory (not returned to client) */
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

/** Rank properties by score (desc), then by createdAt (newest first); return top 3. Does not mutate input or write to Firestore. */
function rankPropertyResults(
  properties: Record<string, unknown>[],
  requestedAreaCode: string,
  nearbyAreaCodes: string[],
  userBudget: number | null
): Record<string, unknown>[] {
  if (properties.length === 0) return [];
  const nowMs = Date.now();
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

// ---------------------------------------------------------------------------
// Property Recommendation Engine (when main + nearby both return 0)
// ---------------------------------------------------------------------------

export interface FindSimilarParams {
  requestedAreaCode: string;
  propertyType: string;
  userBudget?: number | null;
  nearbyAreaCodes: string[];
  requestedSize?: number | null;
}

/** Similarity score in memory only; uses existing properties fields. */
function scoreSimilarProperty(
  prop: Record<string, unknown>,
  userBudget: number | null,
  requestedSize: number | null,
  nowMs: number
): number {
  let score = 40; // +40 same property type (query already filters by type)
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

/**
 * Find similar properties in nearby areas; filter by budget band; rank by similarity in memory; return top 3.
 * Does not change Firestore schema. Limit 20 docs from Firestore.
 */
export async function findSimilarProperties(params: FindSimilarParams): Promise<Record<string, unknown>[]> {
  const { propertyType, userBudget, nearbyAreaCodes, requestedSize } = params;
  if (!propertyType?.trim()) return [];
  const areas = (nearbyAreaCodes || []).filter((a) => a != null && String(a).trim() !== "");
  if (areas.length === 0) return [];

  const areaList = areas.length > 10 ? areas.slice(0, 10) : areas;
  const q = db
    .collection("properties")
    .where("type", "==", propertyType.trim())
    .where("status", "==", "active")
    .where("areaCode", "in", areaList)
    .limit(20);
  const snap = await q.get();
  const docs = snap.docs.map((d) => ({ id: d.id, ...d.data() } as Record<string, unknown>));

  let filtered = docs;
  const budget = userBudget != null && userBudget > 0 ? userBudget : null;
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

  let marketSignal: string = "normal";
  const { requestedAreaCode } = params;
  const pType = params.propertyType?.trim();
  if (requestedAreaCode?.trim() && pType) {
    try {
      const [demandRes, supplyRes] = await Promise.all([
        getMarketDemandStats(requestedAreaCode.trim(), pType),
        getMarketSupplyStats(requestedAreaCode.trim(), pType),
      ]);
      marketSignal = analyzeMarket(demandRes.demandLast7Days, supplyRes.supplyCount);
    } catch {
      // non-fatal
    }
  }
  for (const prop of recommendations) {
    const areaCode = (prop.areaCode as string) || "";
    const sameArea = recommendations.filter((p) => ((p.areaCode as string) || "") === areaCode);
    const prices = sameArea.map((p) => (typeof p.price === "number" ? p.price : Number(p.price))).filter((n) => !Number.isNaN(n));
    const avgPrice = prices.length > 0 ? prices.reduce((a, b) => a + b, 0) / prices.length : null;
    prop.labels = computePropertyLabels(prop, marketSignal, nowMs, avgPrice);
  }

  return recommendations;
}

const SIMILAR_INTRO_AR = "ما لقيت عقار مطابق تماماً لطلبك،\nلكن لقيت عقارات قريبة ممكن تناسبك:\n\n";
const SIMILAR_INTRO_EN = "No exact match for your request,\nbut here are similar properties that might work:\n\n";

function formatSimilarReplyAr(results: Record<string, unknown>[]): string {
  const lines = results.map((r) => {
    const area = (r.areaAr as string) || (r.areaEn as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    const priceStr = price >= 1000 ? `${Math.round(price / 1000)} ألف` : String(price);
    return `• عقار في ${area} – السعر ${priceStr}`;
  });
  return SIMILAR_INTRO_AR + lines.join("\n");
}

function formatSimilarReplyEn(results: Record<string, unknown>[]): string {
  const lines = results.map((r) => {
    const area = (r.areaEn as string) || (r.areaAr as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    return `• Property in ${area} – KWD ${price}`;
  });
  return SIMILAR_INTRO_EN + lines.join("\n");
}

// ---------------------------------------------------------------------------
// Conversation memory (in-memory only; not stored in Firestore)
// ---------------------------------------------------------------------------

export interface SessionMemory {
  areaCode?: string;
  propertyType?: string;
  serviceType?: string;
  budget?: number;
  bedrooms?: number;
}

const SESSION_MEMORY_KEYS = ["areaCode", "type", "serviceType", "budget", "bedrooms"] as const;

/** Triggers that indicate user is starting a completely new search; reset memory and use only new params */
const NEW_SEARCH_TRIGGERS = ["أبي", "ابي", "دور لي", "أبحث عن", "ابحث عن"];

function isNewSearchTrigger(text: string): boolean {
  const t = normalizeArabic((text || "").trim());
  return NEW_SEARCH_TRIGGERS.some((trigger) => t.startsWith(normalizeArabic(trigger)) || t === normalizeArabic(trigger));
}

/** Extract session memory from currentFilters (only allowed keys) */
function getSessionMemory(filters: Record<string, unknown>): SessionMemory & Record<string, unknown> {
  const mem: SessionMemory & Record<string, unknown> = {};
  const areaCode = filters.areaCode;
  if (areaCode != null && String(areaCode).trim() !== "") mem.areaCode = String(areaCode).trim();
  const type = filters.type;
  if (type != null && String(type).trim() !== "") mem.propertyType = String(type).trim();
  const serviceType = filters.serviceType;
  if (serviceType != null && String(serviceType).trim() !== "") mem.serviceType = String(serviceType).trim();
  const budget = filters.budget;
  if (budget != null && typeof budget === "number" && !Number.isNaN(budget)) mem.budget = budget;
  const bedrooms = filters.bedrooms;
  if (bedrooms != null && typeof bedrooms === "number" && !Number.isNaN(bedrooms)) mem.bedrooms = bedrooms;
  return mem;
}

/** Merge session memory with new params: new values override, missing keys keep previous. */
function mergeSessionMemory(
  sessionMemory: SessionMemory & Record<string, unknown>,
  paramsPatch: Record<string, unknown>
): Record<string, unknown> {
  const merged: Record<string, unknown> = {};
  for (const key of SESSION_MEMORY_KEYS) {
    const newVal = paramsPatch[key];
    const prevVal = key === "type" ? sessionMemory.propertyType ?? sessionMemory[key] : sessionMemory[key];
    if (newVal != null && newVal !== "") {
      merged[key] = newVal;
    } else if (prevVal != null && prevVal !== "") {
      merged[key] = prevVal;
    }
  }
  return merged;
}

export const aqaraiAgentRankResults = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }
    const data = (request.data as Record<string, unknown>) || {};
    const properties = Array.isArray(data.properties) ? (data.properties as Record<string, unknown>[]) : [];
    const requestedAreaCode = typeof data.requestedAreaCode === "string" ? data.requestedAreaCode.trim() : "";
    const nearbyAreaCodes = Array.isArray(data.nearbyAreaCodes)
      ? (data.nearbyAreaCodes as string[]).map((s) => String(s).trim()).filter(Boolean)
      : [];
    const userBudget =
      data.userBudget != null && (typeof data.userBudget === "number" || typeof data.userBudget === "string")
        ? Number(data.userBudget)
        : null;

    const top3 = rankPropertyResults(properties, requestedAreaCode, nearbyAreaCodes, userBudget);

    let marketSignal: string = "normal";
    const propertyType = top3[0]?.type != null ? String(top3[0].type).trim() : "";
    if (requestedAreaCode && propertyType) {
      try {
        const [demandRes, supplyRes] = await Promise.all([
          getMarketDemandStats(requestedAreaCode, propertyType),
          getMarketSupplyStats(requestedAreaCode, propertyType),
        ]);
        marketSignal = analyzeMarket(demandRes.demandLast7Days, supplyRes.supplyCount);
      } catch {
        // non-fatal; keep normal
      }
    }

    const nowMs = Date.now();
    for (const prop of top3) {
      const areaCode = (prop.areaCode as string) || "";
      const sameArea = top3.filter((p) => ((p.areaCode as string) || "") === areaCode);
      const prices = sameArea.map((p) => (typeof p.price === "number" ? p.price : Number(p.price))).filter((n) => !Number.isNaN(n));
      const avgPrice = prices.length > 0 ? prices.reduce((a, b) => a + b, 0) / prices.length : null;
      prop.labels = computePropertyLabels(prop, marketSignal, nowMs, avgPrice);
    }

    return { top3 };
  }
);

export const aqaraiAgentFindSimilar = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }
    const data = (request.data as Record<string, unknown>) || {};
    const requestedAreaCode = typeof data.requestedAreaCode === "string" ? data.requestedAreaCode.trim() : "";
    const propertyType = typeof data.propertyType === "string" ? data.propertyType.trim() : (typeof data.type === "string" ? data.type.trim() : "");
    const serviceType = typeof data.serviceType === "string" ? data.serviceType.trim() : "";
    const nearbyAreaCodes = Array.isArray(data.nearbyAreaCodes)
      ? (data.nearbyAreaCodes as string[]).map((s) => String(s).trim()).filter(Boolean)
      : [];
    const userBudget =
      data.userBudget != null && (typeof data.userBudget === "number" || typeof data.userBudget === "string")
        ? Number(data.userBudget)
        : null;
    const requestedSize =
      data.requestedSize != null && (typeof data.requestedSize === "number" || typeof data.requestedSize === "string")
        ? Number(data.requestedSize)
        : null;
    const locale = data.locale === "ar" ? "ar" : "en";

    const cacheKey = getCacheKey({
      areaCode: requestedAreaCode || undefined,
      type: propertyType || undefined,
      serviceType: serviceType || undefined,
      budget: userBudget,
    });
    const cached = getCachedResult(cacheKey);
    if (cached != null) {
      console.log("CACHE HIT", cacheKey);
      return cached as { recommendations: Record<string, unknown>[]; reply: string };
    }

    const recommendations = await findSimilarProperties({
      requestedAreaCode,
      propertyType,
      userBudget,
      nearbyAreaCodes,
      requestedSize,
    });

    let reply =
      recommendations.length > 0
        ? locale === "ar"
          ? formatSimilarReplyAr(recommendations)
          : formatSimilarReplyEn(recommendations)
        : "";

    if (reply) {
      const suggestionContext: SuggestionContext = {
        areaCode: requestedAreaCode || undefined,
        propertyType: propertyType || undefined,
        resultsCount: recommendations.length,
      };
      reply = appendSuggestionsToReply(reply, suggestionContext, locale);
    }

    const response = { recommendations, reply };
    setCachedResult(cacheKey, response);
    return response;
  }
);

export const aqaraiAgentAnalyze = onCall(
  { region: "us-central1", secrets: ["OPENAI_API_KEY"] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }
    const data = (request.data as Record<string, unknown>) || {};
    const rawMessage = typeof data.message === "string" ? data.message.trim() : "";
    if (!rawMessage) {
      throw new HttpsError("invalid-argument", "message required");
    }
    const kuwaitiIntent = normalizeKuwaitiIntent(rawMessage);
    let message = rawMessage.split(/\s+/).map((w) => normalizeAreaName(w)).join(" ");
    const last8Messages = Array.isArray(data.last8Messages) ? data.last8Messages : [];
    const currentFilters = (data.currentFilters && typeof data.currentFilters === "object") ? data.currentFilters as Record<string, unknown> : {};
    const sessionMemory = getSessionMemory(currentFilters);
    const top3LastResults = Array.isArray(data.top3LastResults) ? data.top3LastResults : [];

    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      return {
        intent: "general_question",
        params_patch: {},
        reset_filters: false,
        is_complete: false,
        clarifying_questions: ["المساعد مو متصل حالياً. جرب لاحقاً."],
      };
    }

    const context = [
      "Current filters (use for merge):",
      JSON.stringify(currentFilters),
      "Last 3 results (id, areaAr, areaEn, type, price, size):",
      JSON.stringify(top3LastResults.slice(0, 3)),
      "Last 8 messages (role, content):",
      JSON.stringify(last8Messages.slice(-8)),
      "User message:",
      message,
    ].join("\n");

    try {
      const openai = new OpenAI({ apiKey });
      const completion = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: ANALYZE_SYSTEM },
          { role: "user", content: context },
        ],
        max_tokens: 400,
      });
      const content = completion.choices?.[0]?.message?.content?.trim() || "{}";
      const parsed = extractJson(content);
      const intent = typeof parsed.intent === "string" ? parsed.intent : "general_question";
      const paramsPatch = (parsed.params_patch && typeof parsed.params_patch === "object") ? parsed.params_patch as Record<string, unknown> : {};
      const resetFilters = parsed.reset_filters === true;
      const isComplete = parsed.is_complete === true;
      const clarifyingQuestions = Array.isArray(parsed.clarifying_questions)
        ? (parsed.clarifying_questions as unknown[]).map((q) => String(q))
        : [];

      if (kuwaitiIntent.propertyType != null && (paramsPatch.type == null || paramsPatch.type === "")) {
        paramsPatch.type = kuwaitiIntent.propertyType;
      }
      if (kuwaitiIntent.serviceType != null && (paramsPatch.serviceType == null || paramsPatch.serviceType === "")) {
        paramsPatch.serviceType = kuwaitiIntent.serviceType;
      }

      let finalParamsPatch: Record<string, unknown>;
      let finalResetFilters = resetFilters;
      if (isNewSearchTrigger(rawMessage)) {
        finalParamsPatch = { ...paramsPatch };
        finalResetFilters = true;
      } else {
        finalParamsPatch = mergeSessionMemory(sessionMemory, paramsPatch);
        for (const k of Object.keys(paramsPatch)) {
          if (!SESSION_MEMORY_KEYS.includes(k as (typeof SESSION_MEMORY_KEYS)[number])) {
            finalParamsPatch[k] = paramsPatch[k];
          }
        }
      }

      const out: Record<string, unknown> = {
        intent,
        params_patch: finalParamsPatch,
        reset_filters: finalResetFilters,
        is_complete: isComplete,
        clarifying_questions: clarifyingQuestions,
      };
      if (kuwaitiIntent.requestType != null) {
        out.requestType = kuwaitiIntent.requestType;
      }
      if (kuwaitiIntent.features != null && kuwaitiIntent.features.length > 0) {
        out.features = kuwaitiIntent.features;
      }
      if (kuwaitiIntent.floors != null) {
        out.floors = kuwaitiIntent.floors;
      }
      return out;
    } catch (err) {
      console.error("Agent analyze error:", err);
      throw new HttpsError("internal", "تحليل الرسالة فشل. جرب مرة ثانية.");
    }
  }
);

export const aqaraiAgentCompose = onCall(
  { region: "us-central1", secrets: ["OPENAI_API_KEY"] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }
    const data = (request.data as Record<string, unknown>) || {};
    const top3Results = Array.isArray(data.top3Results) ? (data.top3Results as Record<string, unknown>[]) : [];
    const locale = data.locale === "ar" ? "ar" : "en";
    const userAskedForMore = data.userAskedForMore === true;
    const isNearbyFallback = data.isNearbyFallback === true;
    const requestedAreaLabel = typeof data.requestedAreaLabel === "string" ? data.requestedAreaLabel : "";
    const areaCode = typeof data.areaCode === "string" ? data.areaCode.trim() : (top3Results[0]?.areaCode != null ? String(top3Results[0].areaCode).trim() : "");
    const propertyType = typeof data.propertyType === "string" ? data.propertyType.trim() : (data.type != null ? String(data.type).trim() : (top3Results[0]?.type != null ? String(top3Results[0].type).trim() : ""));
    const serviceType = typeof data.serviceType === "string" ? data.serviceType.trim() : "";
    const userBudget = data.userBudget != null && (typeof data.userBudget === "number" || typeof data.userBudget === "string") ? Number(data.userBudget) : undefined;

    const suggestionContext: SuggestionContext = {
      areaCode: areaCode || undefined,
      propertyType: propertyType || undefined,
      serviceType: serviceType || undefined,
      userBudget,
      resultsCount: top3Results.length,
    };

    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      return { reply: locale === "ar" ? "المساعد مو متصل. جرب لاحقاً." : "Assistant unavailable. Try later." };
    }
    if (top3Results.length === 0) {
      const reply = locale === "ar" ? NO_RESULTS_AR : NO_RESULTS_EN;
      return { reply: appendSuggestionsToReply(reply, suggestionContext, locale) };
    }
    if (isNearbyFallback && top3Results.length > 0) {
      const reply = locale === "ar"
        ? formatNearbyReplyAr(top3Results, requestedAreaLabel)
        : formatNearbyReplyEn(top3Results, requestedAreaLabel);
      return { reply: appendSuggestionsToReply(reply, suggestionContext, locale) };
    }
    if (top3Results.length === 1 && userAskedForMore) {
      const reply = locale === "ar" ? SINGLE_RESULT_ASKED_MORE_AR : SINGLE_RESULT_ASKED_MORE_EN;
      return { reply: appendSuggestionsToReply(reply, suggestionContext, locale) };
    }

    let marketInsightPrefix = "";
    if (areaCode && propertyType) {
      try {
        const [demandRes, supplyRes] = await Promise.all([
          getMarketDemandStats(areaCode, propertyType),
          getMarketSupplyStats(areaCode, propertyType),
        ]);
        const signal = analyzeMarket(demandRes.demandLast7Days, supplyRes.supplyCount);
        const areaLabel = requestedAreaLabel || (top3Results[0]?.areaAr as string) || (top3Results[0]?.areaEn as string) || areaCode;
        marketInsightPrefix = getMarketInsightText(signal, areaLabel, locale);
        if (marketInsightPrefix) marketInsightPrefix += "\n\n";
      } catch (err) {
        console.warn("Market stats error (non-fatal):", err);
      }
    }

    try {
      const openai = new OpenAI({ apiKey });
      const systemContent = locale === "ar" ? COMPOSE_SYSTEM_AR : COMPOSE_SYSTEM_EN;
      const completion = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: systemContent },
          { role: "user", content: JSON.stringify(top3Results) },
        ],
        max_tokens: 300,
      });
      const replyBody = completion.choices?.[0]?.message?.content?.trim() || (locale === "ar" ? "لقيت لك خيارات. ميزانيتك كم؟" : "Found some options. What's your budget?");
      let reply = marketInsightPrefix + replyBody;
      reply = appendSuggestionsToReply(reply, suggestionContext, locale);
      return { reply };
    } catch (err) {
      console.error("Agent compose error:", err);
      const fallback = locale === "ar" ? "لقيت لك خيارات. ميزانيتك كم؟" : "Found some options. What's your budget?";
      return { reply: appendSuggestionsToReply(fallback, suggestionContext, locale) };
    }
  }
);
