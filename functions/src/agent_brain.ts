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
import { onCall, HttpsError } from "firebase-functions/v2/https";
import OpenAI from "openai";
import { normalizeAreaName } from "./area_normalizer";

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

export const aqaraiAgentAnalyze = onCall(
  { region: "us-central1", secrets: ["OPENAI_API_KEY"] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "يجب تسجيل الدخول");
    }
    const data = (request.data as Record<string, unknown>) || {};
    let message = typeof data.message === "string" ? data.message.trim() : "";
    if (!message) {
      throw new HttpsError("invalid-argument", "message required");
    }
    message = message.split(/\s+/).map((w) => normalizeAreaName(w)).join(" ");
    const last8Messages = Array.isArray(data.last8Messages) ? data.last8Messages : [];
    const currentFilters = (data.currentFilters && typeof data.currentFilters === "object") ? data.currentFilters as Record<string, unknown> : {};
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
      return {
        intent,
        params_patch: paramsPatch,
        reset_filters: resetFilters,
        is_complete: isComplete,
        clarifying_questions: clarifyingQuestions,
      };
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
    const top3Results = Array.isArray(data.top3Results) ? data.top3Results : [];
    const locale = data.locale === "ar" ? "ar" : "en";

    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      return { reply: locale === "ar" ? "المساعد مو متصل. جرب لاحقاً." : "Assistant unavailable. Try later." };
    }
    if (top3Results.length === 0) {
      return { reply: locale === "ar" ? NO_RESULTS_AR : NO_RESULTS_EN };
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
      const reply = completion.choices?.[0]?.message?.content?.trim() || (locale === "ar" ? "لقيت لك خيارات. ميزانيتك كم؟" : "Found some options. What's your budget?");
      return { reply };
    } catch (err) {
      console.error("Agent compose error:", err);
      return { reply: locale === "ar" ? "لقيت لك خيارات. ميزانيتك كم؟" : "Found some options. What's your budget?" };
    }
  }
);
