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
import { parseUserMessage, normalizeKuwaitiIntent } from "./intent_parser";
import { mergeContextForTurn } from "./context_updater";
import {
  rankPropertyResults,
  computePropertyLabels,
  findSimilarProperties,
  type FindSimilarParams,
} from "./ranking_engine";
import { getMarketSignal } from "./insight_engine";
import { buildInsights } from "./insight_engine";
import { buildSmartSuggestions } from "./suggestion_engine";
import { composeAssistantResponse } from "./response_composer";

const db = admin.firestore();

// ---------------------------------------------------------------------------
// Cache (60s TTL)
// ---------------------------------------------------------------------------

const SEARCH_CACHE = new Map<string, { data: unknown; timestamp: number }>();
const CACHE_TTL_MS = 60000;

function getCacheKey(params: {
  areaCode?: string;
  type?: string;
  serviceType?: string;
  budget?: number | null;
}): string {
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
  if (Date.now() - entry.timestamp > CACHE_TTL_MS) {
    SEARCH_CACHE.delete(key);
    return null;
  }
  return entry.data;
}

function setCachedResult(key: string, data: unknown): void {
  SEARCH_CACHE.set(key, { data, timestamp: Date.now() });
}

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
  const intro = `حالياً ما لقيت عقار مطابق في ${areaLabel}،\nلكن لقيت عقارات قريبة ممكن تناسبك:\n\n`;
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
  const intro = `No matching property in ${areaLabel} right now.\nFound nearby options that might work:\n\n`;
  const lines = (results as Record<string, unknown>[]).map((r) => {
    const type = (r.type as string) || "";
    const area = (r.areaEn as string) || (r.areaAr as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    return `• ${type} in ${area} – KWD ${price}`;
  });
  return intro + lines.join("\n");
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

function appendSuggestionsToReply(reply: string, suggestions: string[], locale: string): string {
  if (suggestions.length === 0) return reply;
  const prefix = locale === "ar" ? "ممكن أيضاً:\n\n" : "You can also:\n\n";
  return reply + "\n\n" + prefix + suggestions.map((s) => `• ${s}`).join("\n");
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

// ---------------------------------------------------------------------------
// Cloud Functions (orchestrator)
// ---------------------------------------------------------------------------

export const aqaraiAgentRankResults = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
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

    const top3 = rankPropertyResults(properties, {
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

    return { top3 };
  }
);

export const aqaraiAgentFindSimilar = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
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

    const cacheKey = getCacheKey({
      areaCode: requestedAreaCode || undefined,
      type: propertyType || undefined,
      serviceType: undefined,
      budget: userBudget,
    });
    const cached = getCachedResult(cacheKey);
    if (cached != null) {
      console.log("CACHE HIT", cacheKey);
      return cached as { recommendations: Record<string, unknown>[]; reply: string };
    }

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

    const response = { recommendations, reply };
    setCachedResult(cacheKey, response);
    return response;
  }
);

export const aqaraiAgentAnalyze = onCall(
  { region: "us-central1", secrets: ["OPENAI_API_KEY"] },
  async (request) => {
    if (!request.auth) throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
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
    const contextStr = [
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
          { role: "user", content: contextStr },
        ],
        max_tokens: 400,
      });
      const content = completion.choices?.[0]?.message?.content?.trim() || "{}";
      const openaiParsed = extractJson(content);
      const intent = typeof openaiParsed.intent === "string" ? openaiParsed.intent : "general_question";
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

      if (parsed.modifier && hasPreviousSearch && !parsed.isNewSearch) {
        isCompleteFinal = true;
        clarifyingQuestionsFinal = [];
      }

      const mergedForTurn = {
        ...parsed,
        paramsPatch,
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
    const data = (request.data as Record<string, unknown>) || {};
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

    const isAdmin = request.auth?.token?.admin === true;
    const canUseCache = areaCode && !isAdmin;
    if (canUseCache) {
      const cacheKey = getCacheKey({
        areaCode,
        type: propertyType,
        serviceType,
        budget: userBudget,
      });
      const cached = getCachedResult(cacheKey);
      if (cached != null) {
        console.log("CACHE HIT compose", cacheKey);
        return cached as { reply: string; results: Record<string, unknown>[] };
      }
    }

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

      if (canUseCache) {
        const cacheKey = getCacheKey({
          areaCode,
          type: propertyType,
          serviceType,
          budget: userBudget,
        });
        setCachedResult(cacheKey, { reply: payload.reply, results: top3Results });
      }
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
);
