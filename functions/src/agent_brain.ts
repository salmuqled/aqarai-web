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

const ANALYZE_SYSTEM = `You are a Kuwaiti Real Estate Expert agent. You output STRICT JSON only, no other text.

Normalize Arabic to DB keys:
- Areas: القادسية->qadisiya, النزهة->nuzha, السالمية->salmiya, الدسمة->dasma, الشامية->shamiya, الخالدية->khaldiya, كيفان->kaifan, الجابرية->jabriya, الفروانية->farwaniya, حولي->hawalli, الأحمدي->ahmadi, الجهراء->jahra, مبارك الكبير->mubarak_al_kabeer (use lowercase, underscores for spaces).
- Property types: بيت/قسيمة/دار->house, شقة->apartment, فيلا->villa, شاليه->chalet, أرض->land, مكتب->office, محل->shop.

Follow-ups:
- "أرخص" / "ارخص": decrease budget by 10% if budget exists (params_patch.budget = current*0.9), else is_complete=false, clarifying_questions ask for budget.
- "أكبر" / "اكبر": increase size preference (could set a note; keep params_patch minimal).
- "غير المنطقة" / "غير المنطقة للنزهة": reset_filters=true, then if new area given set params_patch.areaCode (e.g. nuzha).

Output ONLY valid JSON in this exact shape (no markdown, no \`\`\`):
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
  "clarifying_questions": ["..."]
}

Rules:
- intent greeting: for سلام/هلا/مرحبا/السلام عليكم with no search intent -> is_complete=false, clarifying_questions can be empty or friendly.
- For search: areaCode is REQUIRED. If missing set is_complete=false and add one short Arabic question in clarifying_questions (e.g. "في أي منطقة تبحث؟").
- Never invent numbers. If budget/bedrooms not in message or context, set null in params_patch.
- Only overwrite keys in params_patch that you infer; use null for absent. Merge with currentFilters on client.
- reset_filters: true only when user says change area / غير المنطقة / بدل المنطقة.`;

const COMPOSE_SYSTEM_AR = `You are a Kuwaiti real estate agent. Given 1-3 property results, write a SHORT marketing reply in Arabic (Kuwaiti dialect).
- Mention 1-3 best options briefly (type, area, price in د.ك).
- Be natural, persuasive, friendly.
- End with exactly ONE short follow-up question (e.g. "ميزانيتك كم؟" or "زاوية ولا شارع؟" or "تبي تزيد غرف؟").
- No lists or bullet points; one short paragraph.`;

const COMPOSE_SYSTEM_EN = `You are a Kuwaiti real estate agent. Given 1-3 property results, write a SHORT marketing reply in English.
- Mention 1-3 best options briefly (type, area, price in KWD).
- Be natural, persuasive, friendly.
- End with exactly ONE short follow-up question (e.g. "What's your budget?" or "Corner or single street?").
- One short paragraph.`;

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
    const message = typeof data.message === "string" ? data.message.trim() : "";
    if (!message) {
      throw new HttpsError("invalid-argument", "message required");
    }
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
      return { reply: locale === "ar" ? "ما لقيت عقارات تطابق البحث. جرب فلتر ثاني." : "No properties match. Try different filters." };
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
