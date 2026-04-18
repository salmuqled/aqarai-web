/**
 * AI Agent Brain: orchestrator only. Delegates to search_context, intent_parser,
 * context_updater, query_builder, ranking_engine, insight_engine, suggestion_engine, response_composer.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import OpenAI from "openai";
import { normalizeAreaName } from "./area_normalizer";
import {
  getSearchContextFromFilters,
  contextToQueryFilters,
  type SearchContext,
} from "./search_context";
import {
  parseUserMessage,
  normalizeKuwaitiIntent,
  resolveTop3ResultReference,
  normalizeTop3MemoryRows,
  extractAreaFromText,
} from "./intent_parser";
import { resolveAreaCodeFromMessage } from "./resolve_area_code_text";
import { mergeContextForTurn } from "./context_updater";
import {
  rankPropertyResults,
  computePropertyLabels,
  findSimilarProperties,
  listingPricePositiveFinite,
  type FindSimilarParams,
} from "./ranking_engine";
import { getMarketSignal } from "./insight_engine";
import { buildInsights } from "./insight_engine";
import { buildSmartSuggestions } from "./suggestion_engine";
import { composeAssistantResponse } from "./response_composer";
import { assertAiRateLimit } from "./aiRateLimit";

const db = admin.firestore();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function extractJson(text: string): Record<string, unknown> {
  const trimmed = text.trim();
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) throw new Error("No JSON object in response");
  return JSON.parse(trimmed.substring(start, end + 1)) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Static reply strings and formatters
// ---------------------------------------------------------------------------

const ANALYZE_SYSTEM = `You are a Kuwaiti real estate expert. Mode: SEARCH FIRST — ASK LATER. Extract whatever the user provides and allow search immediately. Return JSON only.

Normalize Arabic to DB keys:
- Areas: القادسية->qadisiya, النزهة->nuzha, السالمية->salmiya, الدسمة->dasma, الشامية->shamiya, الخالدية->khaldiya, كيفان->kaifan, الجابرية->jabriya, الفروانية->farwaniya, حولي->hawalli, الأحمدي->ahmadi, الجهراء->jahra, مبارك الكبير->mubarak_al_kabeer (lowercase, underscores for spaces).
- Spelling variants count as the same area: e.g. الجهرا/جهراء->jahra; القادسيه/القادسيا->qadisiya; ة/ه at word end (السالميه, النزهه, المهبوله, الصباحيه) same as canonical ة forms; do not invent area slugs outside this list.
- Property types: بيت/قسيمة/دار->house, شقة->apartment, فيلا->villa, شاليه->chalet, أرض->land, مكتب->office, محل->shop.
- Budget: "حدود 700 ألف" / "700 الف" -> 700000, "500 ألف" -> 500000. Never invent numbers; only from message or currentFilters.

SEARCH FIRST — ASK LATER:
1. From the user message, extract ALL available: areaCode, type, serviceType, budget, bedrooms.
2. Set is_complete=true whenever you have an area (areaCode). Run search with whatever you have; missing type/budget/rooms is OK. The client will search immediately.
3. Only set is_complete=false when area is missing. Then add exactly ONE short Arabic question in clarifying_questions (e.g. "في أي منطقة تبحث؟"). NEVER ask a sequence (area? then type? then budget?). One question only.
4. If user says "ابي بيت بالقادسية حدود 700 ألف": set areaCode=qadisiya, type=house, budget=700000, serviceType=sale (default), is_complete=true. No clarifying_questions.
5. Follow-ups: "أرخص" (without ال) / "أرخص شوي" -> params_patch.budget = current*0.9; "أكبر" -> size note; "غير المنطقة للنزهة" -> reset_filters=true, params_patch.areaCode=nuzha.
6. For house: do not ask about bedrooms. For apartment: you may ask bedrooms. When asking, always ONE question only.
7. LAST 3 RESULTS CONTEXT: You receive top3LastResults with propertyId, price, area, propertyType, rank (1=first shown, 2=second, 3=third). If the user refers to those listings ONLY (not a new area search), set intent=reference_listing, referenced_property_id to exactly one propertyId from that list, is_complete=true, clarifying_questions=[].
   - Arabic: "الأرخص" / "أقل سعر" -> pick lowest price row; "الأغلى" -> highest price; "الثاني" -> rank 2; "الأول" -> rank 1; "الثالث" -> rank 3; "اللي قبل" / "السابق" / "الأخير" -> last shown (highest rank).
   - English: "cheapest", "second", "the previous", "last" -> same logic.
   - If the message mixes a new area or new search ("ابي بالنزهة"), do NOT use reference_listing; use normal search intent instead.

Output ONLY valid JSON (no markdown, no \`\`\`):
{
  "intent": "search_property | greeting | follow_up | general_question | reference_listing | top_demand_chalets",
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
  "clarifying_questions": ["single question or empty array"],
  "referenced_property_id": "string|null"
}

Rules:
- Greeting (سلام/هلا) with no search -> intent=greeting, is_complete=false, clarifying_questions can be empty.
- If area can be inferred from message or currentFilters -> is_complete=true, fill params_patch, clarifying_questions=[].
- If area is missing -> is_complete=false, clarifying_questions=["في أي منطقة تبحث؟"] (one question only).
- Never invent numbers. Merge with currentFilters on client. reset_filters only for "غير المنطقة" / change area.
- referenced_property_id must be null unless intent is reference_listing and the id exists in top3LastResults.
- If the user only wants trending / most-booked chalets (e.g. more demand, popular chalets, top chalets), set intent=top_demand_chalets, is_complete=true, clarifying_questions=[], params_patch can stay empty.`;

const NO_RESULTS_AR = `ما لقيت نفس طلبك بالضبط حالياً، لكن أقدر أتابع لك أول ما ينزل عقار مناسب لك 👌

خلّني أعرف ميزانيتك أو إذا تبي أوسّع لك البحث.

وإذا حاب، أقدر أبلّغك مباشرة أول ما ينزل شيء قريب من طلبك.

أقدر كمان:
1. أبحث لك في مناطق قريبة
2. أعرض لك العقارات المتوفرة
3. أسجّل اهتمامك وأوصّلك إشعار أول ما يصير إعلان جديد.`;

const NO_RESULTS_EN = `I couldn't find an exact match for what you asked for right now, but I can follow up as soon as something suitable is listed.

Tell me your budget, or if you'd like me to widen the search.

If you want, I can notify you as soon as something close to your request goes live.

I can also:
1. Search nearby areas
2. Show available listings
3. Save your interest so you get an alert when a new listing appears.`;

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
  const intro = `ما لقيت عقار مطابق في ${areaLabel} حالياً.\nهذي مناطق قريبة وتعطيك نفس المميزات تقريباً:\n\n`;
  const lines = (results as Record<string, unknown>[]).map((r) => {
    const type = (r.type as string) || "";
    const typeLabel = TYPE_LABEL_AR[type] || type;
    const area = (r.areaAr as string) || (r.areaEn as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    const priceStr = price >= 1000 ? `${Math.round(price / 1000)} ألف` : String(price);
    return `• ${typeLabel} في ${area} – السعر ${priceStr}`;
  });
  const outro =
    "\n\nشوف الخيارات وإذا حاب أركز لك أكثر على منطقة معيّنة أو أرتب لك تواصل.";
  return intro + lines.join("\n") + outro;
}

function formatNearbyReplyEn(results: unknown[], requestedAreaLabel: string): string {
  const areaLabel = requestedAreaLabel || "this area";
  const intro = `No exact match in ${areaLabel} right now.\nThese are nearby areas — you'll get similar benefits to what you're looking for:\n\n`;
  const lines = (results as Record<string, unknown>[]).map((r) => {
    const type = (r.type as string) || "";
    const area = (r.areaEn as string) || (r.areaAr as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    return `• ${type} in ${area} – KWD ${price}`;
  });
  const outro =
    "\n\nHave a look at the options — if you want, I can focus on one area for you or help arrange contact.";
  return intro + lines.join("\n") + outro;
}

const SIMILAR_INTRO_AR =
  "ما لقيت مطابقة تامة لطلبك،\nهذي مناطق قريبة وتعطيك نفس المميزات تقريباً:\n\n";
const SIMILAR_INTRO_EN =
  "No exact match for your request.\nThese are nearby options with similar benefits:\n\n";
const SIMILAR_OUTRO_AR =
  "\n\nشوف الخيارات وإذا حاب أركز لك أكثر على منطقة معيّنة أو أرتب لك تواصل.";
const SIMILAR_OUTRO_EN =
  "\n\nBrowse the options — if you want, I can narrow down to a specific area or help arrange contact.";

function formatSimilarReplyAr(results: Record<string, unknown>[]): string {
  const lines = results.map((r) => {
    const area = (r.areaAr as string) || (r.areaEn as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    const priceStr = price >= 1000 ? `${Math.round(price / 1000)} ألف` : String(price);
    return `• عقار في ${area} – السعر ${priceStr}`;
  });
  return SIMILAR_INTRO_AR + lines.join("\n") + SIMILAR_OUTRO_AR;
}

function formatSimilarReplyEn(results: Record<string, unknown>[]): string {
  const lines = results.map((r) => {
    const area = (r.areaEn as string) || (r.areaAr as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    return `• Property in ${area} – KWD ${price}`;
  });
  return SIMILAR_INTRO_EN + lines.join("\n") + SIMILAR_OUTRO_EN;
}

function appendSuggestionsToReply(reply: string, suggestions: string[], locale: string): string {
  if (suggestions.length === 0) return reply;
  const prefix = locale === "ar" ? "ممكن أيضاً:\n\n" : "You can also:\n\n";
  return reply + "\n\n" + prefix + suggestions.map((s) => `• ${s}`).join("\n");
}

const COMPOSE_SYSTEM_AR = `You are a proactive Kuwaiti real estate broker — sales assistant, not just search. Smart Search Mode: fast, helpful, drive the user toward a decision.

STRICT — NO HALLUCINATION: Only describe properties that exist in the provided JSON array. Use only fields present on each object (type, size, price, area, labels, etc.). No invented addresses, prices, or details.

Each listing may include a "labels" array from the server. Use it ONLY for urgency — never invent labels:
- If "high_demand" is in labels for that listing, prefer this tone (that listing only): "العقار عليه طلب، الأفضل تشوفه بسرعة" — helpful, not alarmist.
- If "good_deal" is in labels (that listing only): "سعره فرصة، لا يطوفك" — friendly nudge, not pushy.
- If "new_listing" is in labels, note briefly it is recent (إعلان جديد / حديث).
If "labels" is missing or empty, do NOT claim demand, bargain, or newness.

Format (Arabic):
1. The array is already ranked: the FIRST object is the best match. Start by clearly highlighting it, e.g. "أفضل خيار لك حالياً هو:" then one line for that property (type, size if present, area if present, price in د.ك) plus any allowed urgency from "labels" only.
2. If there are more listings, add a short line like "وفي خيارات ثانية:" then bullets (•) for the remaining ones — one line each, same facts only.
3. Include a direct CTA using action verbs (اضغط، شوف، أقدر أساعدك، خلني أرتب). Prefer this exact phrasing when it fits: "اضغط على هذا العقار الآن وشوف التفاصيل — وإذا مناسب لك أرتب لك تواصل مباشر". If several listings, you may say "اضغط على أي عقار يعجبك" but keep the same helpful offer — no phone numbers, no WhatsApp, no fake contact (user taps in the app only).
4. End with exactly ONE short question toward a decision — budget, timing, or serious intent. For house: do NOT ask about bedrooms. For apartment: bedrooms or budget is OK.
One question only. Tone: helpful broker, natural Kuwaiti, not aggressive.`;

const COMPOSE_SYSTEM_EN = `You are a proactive Kuwaiti real estate broker — a sales assistant, not just search. Smart Search Mode: fast, helpful, move the user toward action.

STRICT — NO HALLUCINATION: Only describe properties in the provided JSON array. Use only fields on each object. No invented addresses, prices, or details.

Each listing may include a "labels" array from the server. Use ONLY these for urgency — never invent:
- "high_demand" (that listing only): e.g. "There's solid interest in this one — worth taking a quick look" — helpful, not pushy.
- "good_deal" (that listing only): e.g. "The price looks like a strong opportunity — worth checking before it's gone" — friendly, not aggressive.
- "new_listing" → note it is a recent listing.
If labels are missing or empty, do not claim scarcity, bargain, or recency.

Format (English):
1. The array is ranked: the FIRST object is the best match. Open with a clear pick, e.g. "Best option for you right now:" then one line for that property (type, size if present, area if present, price in KWD) plus allowed urgency from "labels" only.
2. If there are more listings, a short "Other options:" then bullets (•) — one line each, facts only.
3. Direct CTA with action verbs (tap, see, I can help, I can arrange). Prefer: "Tap this listing now to see the details — if it's a fit, I can help arrange direct contact for you." With multiple listings: "Tap any listing you like" + same offer. Never invent phone numbers, links, or WhatsApp — the user taps in the app only.
4. Exactly ONE closing question toward a decision: budget, timing, or how serious you are. For house: do not ask about bedrooms. For apartment: bedrooms or budget is OK.
One question total. Warm, professional, not salesy or aggressive.`;

// ---------------------------------------------------------------------------
// Shared rank + compose (used by callables; single source of truth for logic)
// ---------------------------------------------------------------------------

/** Move preferred listing id to front so compose matches reference_listing / "الأرخص" UX. */
function prioritizeTop3ByListingId(top3: Record<string, unknown>[], preferId: string): void {
  const id = preferId.trim();
  if (!id) return;
  const idx = top3.findIndex((p) => String(p.id ?? "") === id);
  if (idx > 0) {
    const [row] = top3.splice(idx, 1);
    top3.unshift(row);
  }
}

async function computeRankedTop3WithLabels(
  properties: Record<string, unknown>[],
  requestedAreaCode: string,
  nearbyAreaCodes: string[],
  userBudget: number | null
): Promise<Record<string, unknown>[]> {
  const sane = properties.filter(listingPricePositiveFinite);
  const top3 = rankPropertyResults(sane, {
    requestedAreaCode,
    nearbyAreaCodes,
    userBudget,
  });

  let marketSignal = "normal";
  const propertyType = top3[0]?.type != null ? String(top3[0].type).trim() : "";
  if (requestedAreaCode && propertyType) {
    try {
      marketSignal = await getMarketSignal(db, requestedAreaCode, propertyType);
    } catch {
      // non-fatal
    }
  }

  const nowMs = Date.now();
  for (const prop of top3) {
    const areaCode = (prop.areaCode as string) || "";
    const sameArea = top3.filter((p) => ((p.areaCode as string) || "") === areaCode);
    const prices = sameArea
      .map((p) => (typeof p.price === "number" ? p.price : Number(p.price)))
      .filter((n) => !Number.isNaN(n));
    const avgPrice = prices.length > 0 ? prices.reduce((a, b) => a + b, 0) / prices.length : null;
    prop.labels = computePropertyLabels(prop, marketSignal, nowMs, avgPrice);
  }

  return top3;
}

// ---------------------------------------------------------------------------
// Top-demand chalets (same Firestore rules as getTopDemandChalets; agent-only)
// ---------------------------------------------------------------------------

const TOP_DEMAND_INTENT = "top_demand_chalets";
/** Confirmed bookings in rolling window at or above this count get the high-demand line + label. */
const TOP_DEMAND_HIGH_BOOKINGS = 5;
/** Fetch extra chalet candidates so post-filters (e.g. budget) still allow ranking + fallback. */
const TOP_DEMAND_FETCH_POOL = 48;
const TOP_DEMAND_REPLY_CAP = 10;

function detectTopDemandChaletsIntent(message: string): boolean {
  const t = (message || "").trim();
  if (!t) return false;
  const lower = t.toLowerCase();
  if (lower.includes("popular chalets") || lower.includes("top chalets")) return true;
  const n = lower
    .replace(/[\u064B-\u065F\u0670\u0640]/g, "")
    .replace(/أ|إ|آ/g, "ا")
    .replace(/ى/g, "ي")
    .replace(/ة/g, "ه")
    .replace(/ؤ/g, "و")
    .replace(/ئ/g, "ي")
    .replace(/\s+/g, " ");
  return (
    n.includes("الاكثر طلب") ||
    n.includes("اكثر الشاليهات حجز") ||
    n.includes("اكثر الشاليات حجز") ||
    n.includes("شاليهات الاكثر") ||
    n.includes("الشاليهات الاكثر طلبا") ||
    n.includes("الاكثر طلبا من الشاليهات")
  );
}

function buildTopDemandPropertyTitle(data: admin.firestore.DocumentData | undefined): string {
  if (!data) return "";
  const tit = typeof data.title === "string" ? data.title.trim() : "";
  if (tit) return tit;
  const area = String(data.areaAr ?? data.area ?? data.areaEn ?? "").trim();
  const typ = String(data.type ?? "").trim();
  if (area && typ) return `${area} • ${typ}`;
  return area || typ || "";
}

function isChaletPropertyDoc(data: admin.firestore.DocumentData | undefined): boolean {
  return String(data?.type ?? "")
    .trim()
    .toLowerCase() === "chalet";
}

interface TopDemandAgentRow {
  propertyId: string;
  title: string;
  price: number;
  /** `daily` | `monthly` | `yearly` | `full` — from Firestore or inferred. */
  priceType: string;
  bookingsCount: number;
  cardData: Record<string, unknown>;
}

interface TopDemandUserContext {
  budget?: number;
  nights?: number;
  areaCode?: string;
}

function readBudgetFromFiltersRecord(f: Record<string, unknown>): number | undefined {
  const b = f.budget;
  const n = typeof b === "number" ? b : typeof b === "string" ? Number(String(b).replace(/,/g, "")) : NaN;
  return Number.isFinite(n) && n > 0 ? n : undefined;
}

function readAreaCodeFromFiltersRecord(f: Record<string, unknown>): string | undefined {
  const a = f.areaCode;
  const s = a != null ? String(a).trim().toLowerCase() : "";
  return s !== "" ? s : undefined;
}

function topDemandConversationBlob(rawMessage: string, last8Messages: unknown[]): string {
  const parts: string[] = [];
  const r = rawMessage.trim();
  if (r) parts.push(r);
  for (const row of last8Messages) {
    if (!row || typeof row !== "object") continue;
    const rec = row as Record<string, unknown>;
    const c = rec.content;
    if (typeof c === "string" && c.trim()) parts.push(c.trim());
  }
  return parts.join("\n");
}

/** Budget / nights / area from filters + recent messages (compose-side only). */
function extractTopDemandUserContext(
  rawMessage: string,
  last8Messages: unknown[],
  currentFilters: Record<string, unknown>
): TopDemandUserContext {
  const blob = topDemandConversationBlob(rawMessage, last8Messages);
  const ctxFromFilters = getSearchContextFromFilters(currentFilters);
  let budget = ctxFromFilters.budget ?? readBudgetFromFiltersRecord(currentFilters);
  let areaCode = ctxFromFilters.areaCode?.trim().toLowerCase() ?? readAreaCodeFromFiltersRecord(currentFilters);

  if (budget == null) budget = parseBudgetFromConversationBlob(blob);
  if (!areaCode) {
    areaCode =
      resolveAreaCodeFromMessage(blob)?.trim().toLowerCase() ??
      extractAreaFromText(blob)?.trim().toLowerCase() ??
      undefined;
  }
  const nightsRaw = parseNightsFromConversationBlob(blob);
  const out: TopDemandUserContext = {};
  if (budget != null && budget > 0) out.budget = budget;
  if (areaCode != null && areaCode !== "") out.areaCode = areaCode;
  if (nightsRaw != null) {
    const ni = Math.round(Number(nightsRaw));
    if (Number.isInteger(ni) && ni > 0 && ni <= 30) out.nights = ni;
  }
  return out;
}

function parseBudgetFromConversationBlob(text: string): number | undefined {
  const t = text.replace(/\s+/g, " ");
  const mill = /(\d{1,4})\s*(مليون|ملايين)/i.exec(t);
  if (mill) {
    const n = Number(mill[1]);
    if (Number.isFinite(n)) return n * 1_000_000;
  }
  const athousand = /(\d{1,4})\s*(ألف|الف|الآلف)\b/i.exec(t);
  if (athousand) {
    const n = Number(athousand[1]);
    if (Number.isFinite(n)) return n * 1000;
  }
  const k = /(\d{1,4})\s*k\b/i.exec(t.toLowerCase());
  if (k) {
    const n = Number(k[1]);
    if (Number.isFinite(n)) return n * 1000;
  }
  const hudud = /(?:حدود|بحدود|ميزانية|تحت|دون|less than|under|around|~)\s*(\d{2,7})\b/i.exec(t);
  if (hudud) {
    const n = Number(hudud[1]);
    if (Number.isFinite(n)) return n;
  }
  const big = /\b(\d{5,7})\b/.exec(t);
  if (big) {
    const n = Number(big[1]);
    if (Number.isFinite(n)) return n;
  }
  return undefined;
}

function parseNightsFromConversationBlob(text: string): number | undefined {
  const n = normalizeArabicForTopDemand(text);
  if (/ليلتين|ليليتين/.test(n)) return 2;
  if (/ليله واحده|ليلة واحدة|ليله وحده/.test(n)) return 1;
  const m = /(\d{1,2})\s*(ليالي|ليلة|nights?)\b/i.exec(text);
  if (m) {
    const v = parseInt(m[1], 10);
    if (Number.isFinite(v) && v > 0) return Math.min(30, v);
  }
  return undefined;
}

function normalizeArabicForTopDemand(text: string): string {
  return String(text || "")
    .replace(/[\u0622\u0623\u0625]/g, "\u0627")
    .replace(/\u0629/g, "\u0647")
    .replace(/\u0649/g, "\u064A")
    .replace(/[\u064B-\u0652\u0670]/g, "");
}

/** Must match `PropertyPriceType.legacyMonthlyTypes` in Dart. */
const LEGACY_MONTHLY_TYPES = new Set([
  "apartment",
  "house",
  "villa",
  "office",
  "shop",
  "building",
]);

function inferPriceTypeMissingFromListingType(propertyType: string): string {
  const p = String(propertyType ?? "")
    .trim()
    .toLowerCase();
  if (p === "chalet") return "daily";
  if (LEGACY_MONTHLY_TYPES.has(p)) return "monthly";
  return "full";
}

function normalizePriceTypeFromDoc(raw: unknown, propertyType: string): string {
  const t = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (t === "daily" || t === "monthly" || t === "yearly" || t === "full") return t;
  return inferPriceTypeMissingFromListingType(propertyType);
}

/** Valid listing price for nights / budget math (per-item safety). */
function topDemandRowPriceOk(row: TopDemandAgentRow): boolean {
  const p = row.price;
  return typeof p === "number" && Number.isFinite(p) && p > 0;
}

/** User nights: only when positive integer in context. */
function topDemandUserNights(ctx: TopDemandUserContext): number | undefined {
  const n = ctx.nights;
  if (n == null || !Number.isInteger(n) || n <= 0) return undefined;
  return n;
}

/**
 * Cost vs budget: (price * nights) only when `priceType === 'daily'` and user nights + price OK; else price; invalid price → +∞.
 */
function stayCostForBudgetCompare(row: TopDemandAgentRow, ctx: TopDemandUserContext): number {
  const nights = topDemandUserNights(ctx);
  const priceOk = topDemandRowPriceOk(row);
  const pt = (row.priceType ?? "").trim().toLowerCase();
  if (pt === "daily" && nights != null && priceOk) return row.price * nights;
  if (priceOk) return row.price;
  return Number.POSITIVE_INFINITY;
}

/**
 * Boost `daily` priceType in ranking only for explicit chalet intent or strong
 * chalet + stay-length signals — not for generic rent / apartment context.
 */
function topDemandPrioritizeDailyPriceType(
  ctx: TopDemandUserContext,
  filters: Record<string, unknown>,
  rawMessage: string,
  last8: unknown[]
): boolean {
  const type = typeof filters.type === "string" ? filters.type.trim().toLowerCase() : "";
  if (type === "chalet") return true;
  if (LEGACY_MONTHLY_TYPES.has(type)) return false;

  const blob = topDemandConversationBlob(rawMessage, last8);
  const k = normalizeKuwaitiIntent(blob);
  const hasChaletPhrase = k.propertyType === "chalet";
  const nightsInBlob = parseNightsFromConversationBlob(blob) != null;
  const nightsCtx = topDemandUserNights(ctx) != null;
  return hasChaletPhrase && (nightsInBlob || nightsCtx);
}

/** 1) area match, 2) [optional] daily priceType first, 3) distance |(stay cost) - budget|, 4) bookingsCount (desc). */
function rankTopDemandRows(
  rows: TopDemandAgentRow[],
  ctx: TopDemandUserContext,
  prioritizeDailyPriceType: boolean
): TopDemandAgentRow[] {
  const wantArea = ctx.areaCode?.trim().toLowerCase() ?? "";
  const budget = ctx.budget;
  return [...rows].sort((a, b) => {
    const aAc = String(a.cardData.areaCode ?? "")
      .trim()
      .toLowerCase();
    const bAc = String(b.cardData.areaCode ?? "")
      .trim()
      .toLowerCase();
    const aMatch = wantArea && aAc === wantArea ? 1 : 0;
    const bMatch = wantArea && bAc === wantArea ? 1 : 0;
    if (bMatch !== aMatch) return bMatch - aMatch;
    if (prioritizeDailyPriceType) {
      const aDaily = (a.priceType ?? "").trim().toLowerCase() === "daily" ? 1 : 0;
      const bDaily = (b.priceType ?? "").trim().toLowerCase() === "daily" ? 1 : 0;
      if (bDaily !== aDaily) return bDaily - aDaily;
    }
    if (budget != null && budget > 0) {
      const da = Math.abs(stayCostForBudgetCompare(a, ctx) - budget);
      const db = Math.abs(stayCostForBudgetCompare(b, ctx) - budget);
      if (da !== db) return da - db;
    }
    return b.bookingsCount - a.bookingsCount;
  });
}

/**
 * Mirrors getTopDemandChalets booking aggregation + chalet-only property filter
 * (callable file is unchanged; logic kept in sync here for compose).
 */
async function fetchTopDemandChaletsForAgent(): Promise<TopDemandAgentRow[]> {
  const cutoff = admin.firestore.Timestamp.fromMillis(Date.now() - 7 * 24 * 60 * 60 * 1000);
  const snap = await db
    .collection("bookings")
    .where("status", "==", "confirmed")
    .where("confirmedAt", ">=", cutoff)
    .get();

  const counts = new Map<string, number>();
  for (const doc of snap.docs) {
    const d = doc.data();
    const pid = typeof d.propertyId === "string" ? d.propertyId.trim() : "";
    if (!pid) continue;
    counts.set(pid, (counts.get(pid) ?? 0) + 1);
  }

  const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  const out: TopDemandAgentRow[] = [];

  for (const [propertyId, bookingsCount] of sorted) {
    if (out.length >= TOP_DEMAND_FETCH_POOL) break;
    const pSnap = await db.collection("properties").doc(propertyId).get();
    if (!pSnap.exists) continue;
    const pd = pSnap.data()!;
    if (!isChaletPropertyDoc(pd)) continue;

    const priceRaw = pd.price;
    const priceNum =
      typeof priceRaw === "number"
        ? priceRaw
        : typeof priceRaw === "string"
          ? Number(priceRaw)
          : Number(priceRaw);
    const price = Number.isFinite(priceNum) ? priceNum : 0;
    if (!(typeof price === "number" && Number.isFinite(price) && price > 0)) {
      continue;
    }
    const priceType = normalizePriceTypeFromDoc(pd.priceType, String(pd.type ?? ""));

    const cardData: Record<string, unknown> = {
      id: propertyId,
      price,
      priceType,
      type: pd.type != null ? String(pd.type) : "chalet",
      areaAr: pd.areaAr ?? "",
      areaEn: pd.areaEn ?? "",
      areaCode: pd.areaCode ?? "",
      title: typeof pd.title === "string" ? pd.title : "",
      images: Array.isArray(pd.images) ? pd.images : [],
      coverUrl: pd.coverUrl ?? "",
      thumbnails: Array.isArray(pd.thumbnails) ? pd.thumbnails : [],
      size: pd.size,
    };

    out.push({
      propertyId,
      title: buildTopDemandPropertyTitle(pd),
      price,
      priceType,
      bookingsCount,
      cardData,
    });
  }

  return out;
}

async function buildTopDemandChaletsCompose(
  locale: "ar" | "en",
  opts?: {
    currentFilters?: Record<string, unknown>;
    last8Messages?: unknown[];
    rawMessage?: string;
  }
): Promise<{
  reply: string;
  results: Record<string, unknown>[];
}> {
  const rows = (await fetchTopDemandChaletsForAgent()).filter((r) => topDemandRowPriceOk(r));
  if (rows.length === 0) {
    return {
      reply:
        locale === "ar"
          ? "حالياً لا توجد بيانات كافية، جرب لاحقاً"
          : "Not enough data right now — try again later.",
      results: [],
    };
  }

  const currentFilters =
    opts?.currentFilters && typeof opts.currentFilters === "object"
      ? (opts.currentFilters as Record<string, unknown>)
      : {};
  const last8 = Array.isArray(opts?.last8Messages) ? opts!.last8Messages! : [];
  const rawMessage = typeof opts?.rawMessage === "string" ? opts.rawMessage.trim() : "";

  const userCtx = extractTopDemandUserContext(rawMessage, last8, currentFilters);
  const hasBudgetCtx = userCtx.budget != null && userCtx.budget > 0;
  const hasAreaCtx = userCtx.areaCode != null && userCtx.areaCode !== "";
  const hasPersonalization = hasBudgetCtx || hasAreaCtx;

  const budgetMax = hasBudgetCtx ? userCtx.budget! : null;
  let usedBudgetFallback = false;
  let working = [...rows];
  if (budgetMax != null) {
    const within = working.filter((r) => stayCostForBudgetCompare(r, userCtx) <= budgetMax);
    if (within.length > 0) {
      working = within;
    } else {
      usedBudgetFallback = true;
    }
  }

  const prioritizeDaily = topDemandPrioritizeDailyPriceType(
    userCtx,
    currentFilters,
    rawMessage,
    last8
  );
  const ranked = rankTopDemandRows(working, userCtx, prioritizeDaily);
  const displayRows = ranked.slice(0, TOP_DEMAND_REPLY_CAP);

  const lines: string[] = [];
  if (usedBudgetFallback) {
    if (locale === "ar") {
      lines.push("ما لقيت شاليهات بنفس المواصفات،", "لكن هذه أقرب الخيارات 👇", "");
    } else {
      lines.push(
        "I couldn't find chalets that match those specs exactly,",
        "but here are the closest options 👇",
        ""
      );
    }
  } else if (hasPersonalization) {
    if (locale === "ar") {
      lines.push("هذه أكثر الشاليهات طلباً المناسبة لك 👇", "");
    } else {
      lines.push("Here are the most in-demand chalets that fit what you asked for 👇", "");
    }
  } else {
    if (locale === "ar") {
      lines.push("هذه أكثر الشاليهات طلباً حالياً 👇", "");
    } else {
      lines.push("Here are the chalets with the most bookings right now 👇", "");
    }
  }

  const wantArea = userCtx.areaCode?.trim().toLowerCase() ?? "";
  const userNights = topDemandUserNights(userCtx);

  for (let i = 0; i < displayRows.length; i++) {
    const r = displayRows[i];
    const idx = i + 1;
    const high = r.bookingsCount >= TOP_DEMAND_HIGH_BOOKINGS;
    const propArea = String(r.cardData.areaCode ?? "")
      .trim()
      .toLowerCase();
    const areaMatched = Boolean(wantArea && propArea === wantArea);
    const stayCost = stayCostForBudgetCompare(r, userCtx);
    const withinBudget =
      Boolean(
        budgetMax != null &&
          Number.isFinite(stayCost) &&
          stayCost !== Number.POSITIVE_INFINITY &&
          stayCost <= budgetMax
      ) && !usedBudgetFallback;
    const showNightsBreakdown =
      userNights != null &&
      topDemandRowPriceOk(r) &&
      (r.priceType ?? "").trim().toLowerCase() === "daily" &&
      Number.isFinite(r.price * userNights);
    const budgetReasonAr = withinBudget
      ? showNightsBreakdown
        ? "إجمالي السعر ضمن ميزانيتك"
        : "ضمن ميزانيتك"
      : null;
    const budgetReasonEn = withinBudget
      ? showNightsBreakdown
        ? "Total for your stay is within your budget"
        : "Within your budget"
      : null;

    if (locale === "ar") {
      lines.push(
        `${idx}) ${r.title}`,
        `السعر: ${r.price} د.ك — عدد الحجوزات المؤكدة (آخر ٧ أيام): ${r.bookingsCount}`
      );
      if (showNightsBreakdown) {
        const total = r.price * userNights!;
        lines.push(`${r.price} × ${userNights} ليالي = ${total} د.ك`);
      }
      if (budgetReasonAr != null) lines.push(budgetReasonAr);
      if (areaMatched) lines.push("قريب من المنطقة المطلوبة");
      if (high) lines.push("🔥 عليه طلب عالي");
      lines.push("عرض الشاليه", "");
    } else {
      lines.push(
        `${idx}) ${r.title}`,
        `Price: KWD ${r.price} — confirmed bookings (last 7 days): ${r.bookingsCount}`
      );
      if (showNightsBreakdown) {
        const total = r.price * userNights!;
        lines.push(`${r.price} × ${userNights} nights = KWD ${total}`);
      }
      if (budgetReasonEn != null) lines.push(budgetReasonEn);
      if (areaMatched) lines.push("Near your preferred area");
      if (high) lines.push("🔥 High demand");
      lines.push("View chalet", "");
    }
  }

  const reply = lines.join("\n").trimEnd();
  const results = displayRows.map((r) => {
    const labels = r.bookingsCount >= TOP_DEMAND_HIGH_BOOKINGS ? ["high_demand"] : [];
    return { ...r.cardData, labels } as Record<string, unknown>;
  });
  return { reply, results };
}

async function composeAgentReply(
  data: Record<string, unknown>
): Promise<{ reply: string; results?: Record<string, unknown>[] }> {
  const top3Results = Array.isArray(data.top3Results) ? (data.top3Results as Record<string, unknown>[]) : [];
  const locale = data.locale === "ar" ? "ar" : "en";
  const userAskedForMore = data.userAskedForMore === true;
  const isNearbyFallback = data.isNearbyFallback === true;
  const requestedAreaLabel = typeof data.requestedAreaLabel === "string" ? data.requestedAreaLabel : "";
  const rawMessage =
    typeof data.rawMessage === "string"
      ? data.rawMessage.trim()
      : typeof data.message === "string"
        ? data.message.trim()
        : "";
  const intentFromClient =
    typeof data.intent === "string" ? data.intent.trim().toLowerCase() : "";
  const topDemandCompose =
    intentFromClient === TOP_DEMAND_INTENT || detectTopDemandChaletsIntent(rawMessage);

  if (topDemandCompose) {
    try {
      const currentFilters =
        data.currentFilters && typeof data.currentFilters === "object"
          ? (data.currentFilters as Record<string, unknown>)
          : {};
      const last8Messages = Array.isArray(data.last8Messages) ? data.last8Messages : [];
      const pack = await buildTopDemandChaletsCompose(locale, {
        currentFilters,
        last8Messages,
        rawMessage,
      });
      return { reply: pack.reply, results: pack.results };
    } catch (err) {
      console.error(
        JSON.stringify({
          tag: "TOP_DEMAND_COMPOSE_ERROR",
          message: err instanceof Error ? err.message : String(err),
        })
      );
      return {
        reply:
          locale === "ar"
            ? "حالياً لا توجد بيانات كافية، جرب لاحقاً"
            : "Not enough data right now — try again later.",
        results: [],
      };
    }
  }

  const areaCode =
    typeof data.areaCode === "string"
      ? data.areaCode.trim()
      : top3Results[0]?.areaCode != null
        ? String(top3Results[0].areaCode).trim()
        : "";
  const propertyType =
    typeof data.propertyType === "string"
      ? data.propertyType.trim()
      : data.type != null
        ? String(data.type).trim()
        : top3Results[0]?.type != null
          ? String(top3Results[0].type).trim()
          : "";
  const serviceType = typeof data.serviceType === "string" ? data.serviceType.trim() : "";
  const userBudget =
    data.userBudget != null &&
    (typeof data.userBudget === "number" || typeof data.userBudget === "string")
      ? Number(data.userBudget)
      : undefined;

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    return {
      reply: locale === "ar" ? "المساعد مو متصل. جرب لاحقاً." : "Assistant unavailable. Try later.",
    };
  }

  const suggestions = buildSmartSuggestions({
    area: areaCode || undefined,
    propertyType: propertyType || undefined,
    serviceType: serviceType || undefined,
    locale,
    resultsCount: top3Results.length,
  });

  if (top3Results.length === 0) {
    const reply = locale === "ar" ? NO_RESULTS_AR : NO_RESULTS_EN;
    return { reply: appendSuggestionsToReply(reply, suggestions, locale) };
  }

  if (isNearbyFallback && top3Results.length > 0) {
    const reply =
      locale === "ar"
        ? formatNearbyReplyAr(top3Results, requestedAreaLabel)
        : formatNearbyReplyEn(top3Results, requestedAreaLabel);
    return { reply: appendSuggestionsToReply(reply, suggestions, locale) };
  }

  if (top3Results.length === 1 && userAskedForMore) {
    const reply = locale === "ar" ? SINGLE_RESULT_ASKED_MORE_AR : SINGLE_RESULT_ASKED_MORE_EN;
    return { reply: appendSuggestionsToReply(reply, suggestions, locale) };
  }

  const areaLabel =
    requestedAreaLabel ||
    (top3Results[0]?.areaAr as string) ||
    (top3Results[0]?.areaEn as string) ||
    areaCode ||
    (locale === "ar" ? "هذه المنطقة" : "this area");

  const context: SearchContext = {
    areaCode: areaCode || undefined,
    propertyType: propertyType || undefined,
    serviceType: serviceType || undefined,
    budget: userBudget,
  };

  try {
    const insights = await buildInsights({
      context,
      areaLabel,
      topResults: top3Results,
      rawMessage: rawMessage || undefined,
      locale,
      db,
    });

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
    const mainReplyBody =
      completion.choices?.[0]?.message?.content?.trim() ||
      (locale === "ar" ? "لقيت لك خيارات. ميزانيتك كم؟" : "Found some options. What's your budget?");

    const payload = composeAssistantResponse({
      locale,
      mainReplyBody,
      results: top3Results,
      insights,
      suggestions,
    });

    return { reply: payload.reply, results: top3Results };
  } catch (err) {
    console.error("Agent compose error:", err);
    const fallback =
      locale === "ar" ? "لقيت لك خيارات. ميزانيتك كم؟" : "Found some options. What's your budget?";
    return {
      reply: appendSuggestionsToReply(fallback, suggestions, locale),
      results: top3Results,
    };
  }
}

// ---------------------------------------------------------------------------
// Cloud Functions (orchestrator)
// ---------------------------------------------------------------------------

export const aqaraiAgentRankResults = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    await assertAiRateLimit(db, request, "agent_rank");
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

    const top3 = await computeRankedTop3WithLabels(properties, requestedAreaCode, nearbyAreaCodes, userBudget);
    return { top3 };
  }
);

export const aqaraiAgentFindSimilar = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    await assertAiRateLimit(db, request, "agent_find_similar");
    const data = (request.data as Record<string, unknown>) || {};
    const requestedAreaCode = typeof data.requestedAreaCode === "string" ? data.requestedAreaCode.trim() : "";
    const propertyType =
      typeof data.propertyType === "string"
        ? data.propertyType.trim()
        : typeof data.type === "string"
          ? data.type.trim()
          : "";
    const nearbyAreaCodes = Array.isArray(data.nearbyAreaCodes)
      ? (data.nearbyAreaCodes as string[]).map((s) => String(s).trim()).filter(Boolean)
      : [];
    const userBudget =
      data.userBudget != null && (typeof data.userBudget === "number" || typeof data.userBudget === "string")
        ? Number(data.userBudget)
        : null;
    const requestedSize =
      data.requestedSize != null &&
      (typeof data.requestedSize === "number" || typeof data.requestedSize === "string")
        ? Number(data.requestedSize)
        : null;
    const locale = data.locale === "ar" ? "ar" : "en";

    const getMarketSignalFn = (areaCode: string, pType: string) => getMarketSignal(db, areaCode, pType);
    const recommendations = await findSimilarProperties(
      {
        requestedAreaCode,
        propertyType,
        userBudget,
        nearbyAreaCodes,
        requestedSize,
      } as FindSimilarParams,
      db,
      getMarketSignalFn
    );

    let reply =
      recommendations.length > 0
        ? locale === "ar"
          ? formatSimilarReplyAr(recommendations)
          : formatSimilarReplyEn(recommendations)
        : "";

    if (reply) {
      const suggestions = buildSmartSuggestions({
        area: requestedAreaCode || undefined,
        propertyType: propertyType || undefined,
        locale,
        resultsCount: recommendations.length,
      });
      reply = appendSuggestionsToReply(reply, suggestions, locale);
    }

    return { recommendations, reply };
  }
);

export const aqaraiAgentAnalyze = onCall(
  { region: "us-central1", secrets: ["OPENAI_API_KEY"] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    await assertAiRateLimit(db, request, "agent_analyze");
    const data = (request.data as Record<string, unknown>) || {};
    const rawMessage = typeof data.message === "string" ? data.message.trim() : "";
    if (!rawMessage) throw new HttpsError("invalid-argument", "message required");

    const locale = data.locale === "ar" ? "ar" : "en";
    const parsed = parseUserMessage(rawMessage, locale);

    if (parsed.greeting) {
      return {
        intent: "greeting",
        params_patch: {},
        reset_filters: false,
        is_complete: false,
        clarifying_questions: [],
        greeting_reply: parsed.greetingReply,
      };
    }

    if (detectTopDemandChaletsIntent(rawMessage)) {
      return {
        intent: TOP_DEMAND_INTENT,
        params_patch: {},
        reset_filters: false,
        is_complete: true,
        clarifying_questions: [],
      };
    }

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

    const currentFilters =
      data.currentFilters && typeof data.currentFilters === "object"
        ? (data.currentFilters as Record<string, unknown>)
        : {};
    const last8Messages = Array.isArray(data.last8Messages) ? data.last8Messages : [];
    const top3LastResults = Array.isArray(data.top3LastResults) ? data.top3LastResults : [];

    const message = rawMessage
      .split(/\s+/)
      .map((w) => normalizeAreaName(w))
      .join(" ");
    const memoryRows = normalizeTop3MemoryRows(top3LastResults);
    const deterministicListingRef = resolveTop3ResultReference(rawMessage, memoryRows, locale);

    const contextStr = [
      "Current filters (use for merge):",
      JSON.stringify(currentFilters),
      "Last 3 results (propertyId, price, area, propertyType, rank):",
      JSON.stringify(memoryRows),
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
          { role: "user", content: contextStr },
        ],
        max_tokens: 400,
      });
      const content = completion.choices?.[0]?.message?.content?.trim() || "{}";
      const openaiParsed = extractJson(content);
      let intent = typeof openaiParsed.intent === "string" ? openaiParsed.intent : "general_question";
      const paramsPatch =
        openaiParsed.params_patch && typeof openaiParsed.params_patch === "object"
          ? (openaiParsed.params_patch as Record<string, unknown>)
          : {};
      const resetFilters = openaiParsed.reset_filters === true;
      let isCompleteFinal = openaiParsed.is_complete === true;
      let clarifyingQuestionsFinal = Array.isArray(openaiParsed.clarifying_questions)
        ? (openaiParsed.clarifying_questions as unknown[]).map((q) => String(q))
        : [];

      const kuwaiti = normalizeKuwaitiIntent(rawMessage);
      if (kuwaiti.propertyType && (paramsPatch.type == null || paramsPatch.type === ""))
        paramsPatch.type = kuwaiti.propertyType;
      if (kuwaiti.serviceType && (paramsPatch.serviceType == null || paramsPatch.serviceType === ""))
        paramsPatch.serviceType = kuwaiti.serviceType;

      let referencedPropertyId = "";
      const fromModelRef =
        typeof openaiParsed.referenced_property_id === "string"
          ? openaiParsed.referenced_property_id.trim()
          : "";
      if (fromModelRef && memoryRows.some((r) => r.propertyId === fromModelRef)) {
        referencedPropertyId = fromModelRef;
      }
      if (!referencedPropertyId && deterministicListingRef) {
        referencedPropertyId = deterministicListingRef;
      }
      if (referencedPropertyId) {
        intent = "reference_listing";
        isCompleteFinal = true;
        clarifyingQuestionsFinal = [];
      }

      if (!referencedPropertyId && intent === TOP_DEMAND_INTENT) {
        isCompleteFinal = true;
        clarifyingQuestionsFinal = [];
      }

      if (!paramsPatch.areaCode && parsed.detectedAreaCode) {
        paramsPatch.areaCode = parsed.detectedAreaCode;
        isCompleteFinal = true;
        clarifyingQuestionsFinal = [];
      }

      const previousContext = getSearchContextFromFilters(currentFilters);
      if (!paramsPatch.areaCode && previousContext.areaCode) paramsPatch.areaCode = previousContext.areaCode;
      if ((!paramsPatch.type || paramsPatch.type === "") && previousContext.propertyType)
        paramsPatch.type = previousContext.propertyType;
      if ((!paramsPatch.serviceType || paramsPatch.serviceType === "") && previousContext.serviceType)
        paramsPatch.serviceType = previousContext.serviceType;
      if (paramsPatch.budget == null && previousContext.budget != null) paramsPatch.budget = previousContext.budget;
      if (paramsPatch.bedrooms == null && previousContext.bedrooms != null)
        paramsPatch.bedrooms = previousContext.bedrooms;

      const hasPreviousSearch =
        (previousContext.areaCode != null && previousContext.areaCode !== "") ||
        (previousContext.budget != null) ||
        (previousContext.propertyType != null && previousContext.propertyType !== "");

      if (parsed.modifier && hasPreviousSearch && !parsed.isNewSearch && !referencedPropertyId) {
        isCompleteFinal = true;
        clarifyingQuestionsFinal = [];
      }

      const mergedForTurn = {
        ...parsed,
        paramsPatch,
        modifier: referencedPropertyId ? null : parsed.modifier,
      };
      const context = mergeContextForTurn(previousContext, mergedForTurn);

      let finalParamsPatch = contextToQueryFilters(context) as Record<string, unknown>;
      if (paramsPatch.investmentFlag != null) finalParamsPatch.investmentFlag = paramsPatch.investmentFlag;

      const finalResetFilters = parsed.isNewSearch ? true : resetFilters;

      const out: Record<string, unknown> = {
        intent,
        params_patch: finalParamsPatch,
        reset_filters: finalResetFilters,
        is_complete: isCompleteFinal,
        clarifying_questions: clarifyingQuestionsFinal,
      };
      if (referencedPropertyId) out.referenced_property_id = referencedPropertyId;
      if (kuwaiti.requestType != null) out.requestType = kuwaiti.requestType;
      if (kuwaiti.features != null && kuwaiti.features.length > 0) out.features = kuwaiti.features;
      if (kuwaiti.floors != null) out.floors = kuwaiti.floors;
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
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    await assertAiRateLimit(db, request, "agent_compose");
    const data = (request.data as Record<string, unknown>) || {};
    return composeAgentReply(data);
  }
);

/** Single round-trip: rank (same as aqaraiAgentRankResults) then compose (same as aqaraiAgentCompose). */
export const aqaraiAgentRankAndCompose = onCall(
  { region: "us-central1", secrets: ["OPENAI_API_KEY"] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    await assertAiRateLimit(db, request, "agent_rank_compose");
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

    const top3 = await computeRankedTop3WithLabels(properties, requestedAreaCode, nearbyAreaCodes, userBudget);

    const preferId =
      typeof data.preferListingIdFirst === "string" ? data.preferListingIdFirst.trim() : "";
    if (preferId) prioritizeTop3ByListingId(top3, preferId);

    const { reply } = await composeAgentReply({ ...data, top3Results: top3 });
    return { top3, reply };
  }
);
