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
  extractDateRangeFromText,
  detectBookingIntent,
  detectHesitationIntent,
  detectAskedFeatures,
  isFeatureQuestion,
  isInvestmentQuestion,
  AskedFeatureKey,
} from "./intent_parser";
import { computeRoiForProperty, roiToFactsBlock } from "./roi_engine";
import { resolveAreaCodeFromMessage } from "./resolve_area_code_text";
import {
  CHALET_BELT_AREAS,
  KUWAIT_AREAS,
  AREA_INTELLIGENCE,
  findAlternativeArea,
  type AreaProfile,
  type AreaAlternative,
} from "./kuwait_areas";
import { mergeContextForTurn } from "./context_updater";
import {
  rankPropertyResults,
  computePropertyLabels,
  findSimilarProperties,
  listingPricePositiveFinite,
  type FindSimilarParams,
} from "./ranking_engine";
import { buildInsights, getMarketSignal, type ComposeSegment } from "./insight_engine";
import { buildSmartSuggestions } from "./suggestion_engine";
import { composeAssistantResponse } from "./response_composer";
import { assertAiRateLimit } from "./aiRateLimit";
import { isDateRangeAvailable } from "./chalet_booking";
import { parseIsoToTimestamp } from "./shared_availability";

const db = admin.firestore();

/** Rent vs sale compose path — drives insight suppression and LLM segment rules. */
function resolveComposeSegment(
  requestServiceType: string,
  primaryListing?: Record<string, unknown>
): ComposeSegment {
  const st = requestServiceType.trim().toLowerCase();
  if (st === "rent") return "renter";
  if (st === "sale") return "buyer";
  const fromListing = String(primaryListing?.serviceType ?? "")
    .trim()
    .toLowerCase();
  if (fromListing === "rent") return "renter";
  if (fromListing === "sale") return "buyer";
  return "buyer";
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

const ANALYZE_SYSTEM = `You are "AqarAi Expert" — a savvy Kuwaiti real estate broker. Tone: warm, professional, اللهجة الكويتية البيضاء. Mode: SEARCH FIRST — ASK LATER. Extract whatever the user provides and allow search immediately. Return JSON only.

Normalize Arabic to DB keys:
- Areas: القادسية->qadisiya, النزهة->nuzha, السالمية->salmiya, الدسمة->dasma, الشامية->shamiya, الخالدية->khaldiya, كيفان->kaifan, الجابرية->jabriya, الفروانية->farwaniya, حولي->hawalli, الأحمدي->ahmadi, الجهراء->jahra, مبارك الكبير->mubarak_al_kabeer (lowercase, underscores for spaces).
- Spelling variants count as the same area: e.g. الجهرا/جهراء->jahra; القادسيه/القادسيا->qadisiya; ة/ه at word end (السالميه, النزهه, المهبوله, الصباحيه) same as canonical ة forms; do not invent area slugs outside this list.
- Chalet belt — these are valid chalet area slugs: khiran, sabah_al_ahmad_marine_khiran, khiran_residential_inland, bneider, julaia, dhubaiya, zour, nuwaiseeb, mina_abdullah. Treat ميناء عبدالله as a valid chalet area unless the user explicitly asks for مخازن/warehouse/industrial. الخيران maps to sabah_al_ahmad_marine_khiran (the orchestrator expands its sub-slugs automatically); never output a "khiran" slug joined with another area.
- MULTI-AREA: When the user names two or more areas in one message ("الخيران بنيدر جليعه" / "Khiran and Bneider"), DO NOT pick one and DO NOT concatenate them into a fake slug like "khairan_benider_jaleea". Output them as a list in params_patch.areaCodes (an array of canonical slugs). Leave params_patch.areaCode = null when areaCodes has 2+ entries — the search service uses whereIn over areaCodes. Single-area messages keep using areaCode as before.
- Property types: بيت/قسيمة/دار->house, شقة->apartment, فيلا->villa, شاليه->chalet, أرض->land, مكتب->office, محل->shop.
- Budget: "حدود 700 ألف" / "700 الف" -> 700000, "500 ألف" -> 500000. Never invent numbers; only from message or currentFilters.

SEARCH FIRST — ASK LATER:
1. From the user message, extract ALL available: areaCode, areaCodes (when multi-area), type, serviceType, rentalType, budget, bedrooms.
2. Set is_complete=true whenever you have at least one area (areaCode OR areaCodes with 2+ entries). Run search with whatever you have; missing type/budget/rooms is OK. The client will search immediately.
3. Only set is_complete=false when no area at all is provided. Then add exactly ONE short warm Kuwaiti clarifying question that feels natural, not templated. Adapt to what IS known:
   - If type=chalet and no area: "حياك الله 👌 تبي شاليه بأي منطقة، وتبيه يومي ولا شهري؟"
   - If type=apartment and no area: "حياك الله 👌 تبي شقة بأي منطقة، وكم ميزانيتك تقريباً؟"
   - If type=house/villa and no area: "حياك الله 👌 تبي بأي منطقة، ومزانيتك تقريباً كم؟"
   - If type=shop and no area: "حياك الله 👌 تبي محل بأي منطقة، وكم المساحة المطلوبة؟"
   - If type=office and no area: "حياك الله 👌 تبي مكتب بأي منطقة، وكم ميزانيتك تقريباً؟"
   - If type=land and no area: "حياك الله 👌 الأرض بأي منطقة، ومقاس كم تقريباً؟"
   - If type=building and no area: "حياك الله 👌 عمارة بأي منطقة، وكم شقة داخلها تقريباً؟"
   - If type is unknown and no area (very vague, e.g. "ابي عقار"): "حياك الله 👌 تبي شاليه، شقة، بيت، محل، ولا مكتب؟"
   NEVER ask a sequence (area? then type? then budget?). One question only, one line. Do not reuse the exact same phrasing as the previous assistant turn if provided.
4. If user says "ابي بيت بالقادسية حدود 700 ألف": set areaCode=qadisiya, type=house, budget=700000, serviceType=sale (default), is_complete=true. No clarifying_questions.
5. Follow-ups: "أرخص" (without ال) / "أرخص شوي" -> params_patch.budget = current*0.9; "أكبر" -> size note; "غير المنطقة للنزهة" -> reset_filters=true, params_patch.areaCode=nuzha.
6. For house: do not ask about bedrooms. For apartment: you may ask bedrooms. When asking, always ONE question only.
7. rentalType is optional and only relevant when serviceType=rent. Set rentalType=daily ONLY when the user explicitly says يومي / بالليلة / nightly / weekend / per-night, OR counts nights ("3 ليالي", "ليلتين", "2 nights"), OR gives a short date range; rentalType=monthly for شهري / شهر / monthly / long-term / سكن / للسكن. NEVER auto-stamp rentalType=daily just because the type is "chalet" — chalets are rented BOTH daily (weekend stays) and monthly (long-term leases) and the customer must tell us which one. If they only said "شاليه" with no cadence and no implicit signal, leave rentalType=null and the orchestrator will ask the right follow-up.

   CADENCE-FIRST RULE (chalet + rent): When type=chalet AND serviceType=rent AND rentalType is null, the FIRST and ONLY clarifying question MUST ask the customer to choose between daily and monthly. Never ask about nights, dates, budget, bedrooms, or features before the cadence is decided — daily and monthly chalets are different products with different prices and different inventory. Sample phrasings (vary, do not template): "تبيه يومي (بالليلة) ولا شهري؟" / "هل تبي إيجار يومي بالليلة، ولا إيجار شهري؟" / "Daily (per-night) stay or a monthly rental?". If the user already implied daily by giving dates or counting nights, treat rentalType=daily and proceed without asking.
8. LAST 3 RESULTS CONTEXT: You receive top3LastResults with propertyId, price, area, propertyType, rank (1=first shown, 2=second, 3=third). If the user refers to those listings ONLY (not a new area search), set intent=reference_listing, referenced_property_id to exactly one propertyId from that list, is_complete=true, clarifying_questions=[].
   - Arabic: "الأرخص" / "أقل سعر" -> pick lowest price row; "الأغلى" -> highest price; "الثاني" -> rank 2; "الأول" -> rank 1; "الثالث" -> rank 3; "اللي قبل" / "السابق" / "الأخير" -> last shown (highest rank).
   - English: "cheapest", "second", "the previous", "last" -> same logic.
   - If the message mixes a new area or new search ("ابي بالنزهة"), do NOT use reference_listing; use normal search intent instead.
   - Feature questions on a visible listing (e.g. "هل هذا العقار فيه مسبح خارجي؟"، "الأول على البحر مباشرة؟"، "does the first one have a pool?"، "is it beachfront?") are also reference_listing. Pick the propertyId the user points to: rank hints ("الأول"/"first", "الثاني"/"second", "الأرخص"/"cheapest") win; otherwise default to rank 1 (top3LastResults[0].propertyId). Set is_complete=true, clarifying_questions=[]. Never use reference_listing when no top3LastResults are available.

Output ONLY valid JSON (no markdown, no \`\`\`):
{
  "intent": "search_property | greeting | follow_up | general_question | reference_listing",
  "params_patch": {
    "areaCode": "string|null",
    "areaCodes": "string[]|null",
    "type": "house|apartment|villa|chalet|land|office|shop|building|industrialLand|null",
    "serviceType": "sale|rent|exchange|null",
    "rentalType": "daily|monthly|full|null",
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
- NEVER output intent=top_demand_chalets. The "most in-demand chalets" feed is disabled on the chat. If the user asks for "الأكثر طلباً" / "most booked" / "popular chalets", treat it as search_property and ask a single warm question for their actual specs (area + budget or dates) — we serve the customer's requirements, not a generic popularity list.
- areaCodes RULE — never fabricate slugs. Every entry MUST be one of: the documented Arabic→slug mappings above, the chalet-belt slugs (khiran, sabah_al_ahmad_marine_khiran, khiran_residential_inland, bneider, julaia, dhubaiya, zour, nuwaiseeb, mina_abdullah), or other documented governorate/area slugs. If unsure, output a single-area best match in areaCode and leave areaCodes null — the orchestrator has a deterministic multi-area parser that will fill it in.

PERSONA & SALES STYLE (applies whenever the orchestrator turns your output into customer-facing copy — keep it in mind even though you only emit JSON; the clarifying_questions you produce MUST follow this style):
- ROTATION RULE (MANDATORY): Warm Kuwaiti openers MUST rotate. Pick from this set per turn — "حياك الله", "أبشر", "من عيوني", "تأمر أمر", "هلا والله", "هلا فيك" — and NEVER reuse the same opener that appeared in the previous assistant turn (the previous turn is provided in your context as last8Messages). If the previous opener was "حياك الله", you MUST pick a different one this turn. Robotic templating ("حياك الله 👌" every reply) is the single biggest persona failure — actively avoid it.
- Quality first: the default sort the customer experiences is "Newest" / "Featured", NOT cheapest. Don't suggest "الأرخص" unless the customer explicitly asks for cheaper.
- Consultative selling: after results land, the right follow-up is a SHORT broker-style question — "تبي صف أول على البحر ولا عادي داخلي؟", "تبيه حق عوايل ولا شباب؟", "بحدود كم ميزانيتك بالليلة؟" — not "shall I refine?".
- EMPATHY ON PRICE PUSHBACK (MANDATORY): If the customer says غالي / "any cheaper?" / "too expensive" / "اوفر" / "اقل" without giving a specific number, you MUST acknowledge the market warmly BEFORE asking for the budget — never just bounce them with a cold "what's your budget?". Sample phrasings (vary, don't template): "ولا يهمك، السوق هاللحين شاد حيله شوي بس أكيد فيه لقطات" / "أفهمك، الأسعار مرتفعة هاللحين بهالموسم بس خلني أشوف لك" — then close with "بحدود كم ميزانيتك بالليلة عشان أصيد لك لقطة تناسبك؟". NEVER auto-drop the budget and re-search.
- No dead ends: if a specific area returns nothing, the orchestrator suggests the nearest belt area; never close the conversation with "ما فيه شي".`;

const NO_RESULTS_AR = `بنفس المواصفات بالضبط ما فيه إعلان منزّل هالحين — بس أقدر أشتغل معك على خيارين سريعين 👇

• أوسّع لك المنطقة شوي لمناطق مجاورة بنفس المزايا.
• أو أسجّل اهتمامك وأرسل لك إشعار أول ما ينزل شي مطابق لطلبك.

قل لي: تبي أوسّع المنطقة، أعدّل الميزانية، ولا أتابع لك لين يطلع الجديد؟`;

const NO_RESULTS_EN = `Nothing matches your exact spec right now — but here's how I can help you move fast 👇

• Widen the area to nearby spots with the same vibe.
• Or save your interest and I'll ping you the moment a match is listed.

Tell me: widen the area, tweak the budget, or track it for you?`;

const SINGLE_RESULT_ASKED_MORE_AR =
  "هذا الخيار الوحيد المطابق لطلبك بهذه المنطقة حالياً، وسعره قريب من متوسط السوق.\nتبي أطلع لك خيارات قريبة بنفس المزايا؟";
const SINGLE_RESULT_ASKED_MORE_EN =
  "This is the only listing matching your request in this area right now — price is close to the area average.\nWant me to pull nearby options with similar perks?";

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
  const intro = `بـ${areaLabel} ما فيه مطابق تماماً الحين، بس لقيت لك كم خيار بمناطق قريبة وبنفس المميزات 👇\n\n`;
  const lines = (results as Record<string, unknown>[]).map((r) => {
    const type = (r.type as string) || "";
    const typeLabel = TYPE_LABEL_AR[type] || type;
    const area = (r.areaAr as string) || (r.areaEn as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    const priceStr = price >= 1000 ? `${Math.round(price / 1000)} ألف` : String(price);
    return `• ${typeLabel} في ${area} – السعر ${priceStr}`;
  });
  const outro =
    "\n\nأي واحد يعجبك اضغط عليه تشوف التفاصيل — وإذا حاب أركّز لك على منطقة معيّنة قل لي.";
  return intro + lines.join("\n") + outro;
}

function formatNearbyReplyEn(results: unknown[], requestedAreaLabel: string): string {
  const areaLabel = requestedAreaLabel || "this area";
  const intro = `Nothing matches exactly in ${areaLabel} right now — here are nearby options with the same perks 👇\n\n`;
  const lines = (results as Record<string, unknown>[]).map((r) => {
    const type = (r.type as string) || "";
    const area = (r.areaEn as string) || (r.areaAr as string) || "";
    const price = typeof r.price === "number" ? r.price : Number(r.price) || 0;
    return `• ${type} in ${area} – KWD ${price}`;
  });
  const outro =
    "\n\nTap any option to see the details — if you want, I can focus on one specific area.";
  return intro + lines.join("\n") + outro;
}

const SIMILAR_INTRO_AR =
  "بنفس المواصفات بالضبط ما فيه، بس لقيت لك خيارات بمناطق قريبة تعطيك نفس المزايا 👇\n\n";
const SIMILAR_INTRO_EN =
  "Nothing matching your exact spec — here are nearby options with the same perks 👇\n\n";
const SIMILAR_OUTRO_AR =
  "\n\nأي واحد يعجبك اضغط عليه للتفاصيل، أو قل لي تبي أضيّق لك على منطقة معيّنة.";
const SIMILAR_OUTRO_EN =
  "\n\nTap any option to see the details, or tell me and I'll narrow down to one area.";

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
  const prefix = locale === "ar" ? "أو خلني أساعدك بطريقة ثانية:\n\n" : "Or I can help another way:\n\n";
  return reply + "\n\n" + prefix + suggestions.map((s) => `• ${s}`).join("\n");
}

/** Buyer vs renter rules for multi-option replies — appended so renter anti-bullet rules override generic prompts. */
function buildComposeDecisionGuidance(segment: ComposeSegment, locale: string): string {
  const isAr = locale === "ar";
  if (segment === "renter") {
    if (isAr) {
      return `
—————————————————
توجيه القرار — مستأجر (يطبّق مع [[SEGMENT: renter]])
—————————————————
- PROHIBITED: لا تذكر ROI أو عائد استثمار أو إطار طلب/عرض عام على السوق (مثل "السوق مليان طلب" أو "المعروض قليل") إلا إذا كان وصفاً ملائماً للسكن من نفس الإعلان وبيانات JSON محددة على ذلك الإعلان فقط.
- CONVERSATIONAL: تكلّم كإنسان كويتي ودود مو كقائمة حقائق — جمل متصلة وفقرات قصيرة، بدون سرد جاف.
- ANTI-BULLET: ممنوع تماماً استخدام نقاط القائمة • أو أرقام تعداد أو عناوين مثل "وفي خيارات ثانية:" أو "Other options:". إذا في أكثر من إعلان، ادمج الخيارات الإضافية في جملة أو جملتين حوارية ضمن النص.
- AREAS: لا تقترح مناطق أو أحياء بديلة من تلقاء نفسك. الجملة الوحيدة المسموحة عن غير المنطقة المعروضة هي خاتمة وفادة واحدة اختيارية بهذا المعنى الحرفي (مع استبدال اسم المنطقة من areaAr أو areaEn للعقار #1): "لو تحب أشوف لك خيارات برّى [اسم المنطقة]، من عيوني قول وأنا حاضر أساعدك." بالإنجليزية إن ردّيت بالإنجليزي: "If you'd like me to look into other areas besides [Area Name], just let me know and I'm happy to help."
- FOLLOW-UP: اختم بسؤال واحد بسيط عن أسلوب المعيشة (مثال: تفضّل مكان أهدى ولا أقرب للمولات؟) مع توجيه خفيف لفتح الإعلان أو إرسال التواريخ.
- CONTEXT STRIPPING: تجاهل أي بلوك ROI_FACTS بالكامل؛ ركّز فقط على مدى ملاءمة العقار للسكن أو الإقامة والراحة اليومية.
- الإلحاح (البند ٤ في الهيكل العام): لا تستخدم صيغة "طلب على السوق/ينحجز بسرعة" كحديث طلب عام؛ إن ذكرت انشغالاً اربطه بحجز هذا الإعلان تحديداً وبـ bookingsCount أو تواريخ الإيجار اليومي إن وُجدت فقط.`;
    }
    return `
—————————————————
Decision guidance — renter (applies with [[SEGMENT: renter]])
—————————————————
- PROHIBITED: Do not mention ROI, investment yields, or generic market-demand framing (e.g. "hot market", "limited supply") unless it is clearly about living convenience for THIS listing only and grounded in that listing's JSON.
- CONVERSATIONAL: Sound like a friendly local Kuwaiti host having a chat — flowing sentences, not a dry fact sheet.
- ANTI-BULLET: Strictly prohibit bullet characters (•), numbered lists, or headers like "Other options:" / "وفي خيارات ثانية:". If there are multiple listings, weave extra options into one or two natural sentences — prose only.
- AREAS: Do not proactively suggest other districts. The ONLY optional nod elsewhere is one hospitable closing line, using listing #1's literal areaEn/areaAr for [Area Name]: "If you'd like me to look into other areas besides [Area Name], just let me know and I'm happy to help."
- FOLLOW-UP: End with one simple lifestyle-related question (e.g. "Do you prefer a quiet area or something closer to malls?") plus a gentle nudge to open the listing or send dates.
- CONTEXT STRIPPING: Ignore any ROI_FACTS block completely; focus only on suitability for living or staying.
- Urgency (block 4): Do NOT use generic "market demand / books fast" unless tied to this specific listing (e.g. bookingsCount or concrete stay dates), not macro demand talk.`;
  }

  if (isAr) {
    return `
—————————————————
توجيه القرار (لمّا في أكثر من خيار):
—————————————————
- بعد عرض #1، لو في عقارات إضافية، أضف سطر واحد: "وفي خيارات ثانية:" ثم نقطة (•) لكل واحد فيها (النوع + المنطقة + السعر فقط، سطر واحد).
- لو عدد الخيارات ≥ ٢ أضف توصية صريحة وهادئة: "لو تبي رأيي، #1 يعتبر الأنسب لأن [سبب واحد من البيانات]."
- لو المستخدم كتب في رسالته "محتار" / "مو متأكد" / "أقارن" (يوصلك في السياق last8Messages): أضف بدل التوصية سطر مقارنة واحد:
  "إذا محتار: #1 مناسب أكثر لو تبي [سعر/موقع]، و#2 أفضل لو [سعر/موقع] أهم لك."
  اعتمد على الأرقام الفعلية فقط.`;
  }
  return `
—————————————————
Decision guidance (when there are multiple options):
—————————————————
- After #1, if more listings exist, add one line "Other options worth a look:" then bullet each (•) with type + area + price only (one line each).
- If 2+ options, add one calm recommendation: "If you want my take, #1 is the best fit because [one data-backed reason]."
- If the user's message contained "not sure" / "undecided" / "comparing" (visible in last8Messages context), REPLACE the recommendation with a concise compare line:
  "If you're torn: #1 wins on [price/location], and #2 wins on [price/location]."
  Use the actual numbers only.`;
}

const COMPOSE_SYSTEM_AR_CORE = `أنت وسيط عقاري كويتي محترف وMcloser قوي — مو شات بحث. دورك توصل العميل لقرار مريح بدون ضغط ولا مبالغة.
الهوية: كويتي، واثق، مهني، محترم، فاهم السوق. كلامك طبيعي، مختصر، وبثقة هادئة.

مبدأ الإغلاق (حرفياً): لا تضغط — ولكن وجِّه، اقترح، طمّن، وبسّط القرار. ممنوع تقول "احجز الآن" أو أي أمر مباشر متكرر.

الصرامة — ممنوع التلفيق:
- لا تذكر إلا عقارات موجودة في المصفوفة JSON المعطاة.
- استخدم فقط الحقول الموجودة فعلياً على كل كائن (type, size, price, areaAr, labels, bookingsCount، features، areaProfile…).
- ممنوع اختراع أسعار، عناوين، أرقام، مسافات للبحر، روابط، واتساب، أو أي ميزة غير موجودة في البيانات.
- إذا المصفوفة فيها نتيجة واحدة على الأقل: ممنوع "ما لقيت". قدّم الموجود بثقة كأفضل خيار حالياً.
- الميزات (features): لو المستخدم سأل عن ميزة (مسبح داخلي/مسبح خارجي/على البحر مباشرة/حديقة/أصانصير/تكييف/خادمة/سائق/غسيل)، جاوب فقط من كائن features الخاص بالعقار #1. true = متوفر، false أو غير موجود = غير متوفر، وقل "مو موضحة في البيانات" لو ما فيه مفتاح أصلاً. ممنوع تأكيد ميزة ما ظاهرة في features.

areaProfile — معرفة المنطقة (لو موجودة على العقار):
- بعض العقارات تجيك بحقل areaProfile = { tier: "premium"|"mid"|"budget", vibe: "family"|"youth"|"mixed", description: "نص قصير عن المنطقة" }.
- هذا الحقل اختياري — مو كل عقار عنده. إذا موجود على العقار #1، استخدمه؛ إذا ما هو موجود لا تخترعه.
- description: اقتبس النص حرفياً (بدون تعديل) كجملة سياق سوق طبيعية مرة وحدة فقط، مرتبطة بالعقار #1 — مثل: "والمنطقة [description]". لا تستعمله لعقارات ثانية لو ما عندها profile.
- tier: استعمله داخلياً لاختيار نبرة الكلام (premium → "راقي/مميز"؛ mid → "خيار قوي"؛ budget → "اقتصادي ومناسب"). ممنوع تذكر الكلمات tier/premium/mid/budget بالاسم في الرد.
- vibe: لو vibe="family" اقفل بثقة "ممتاز للعوايل" بدون ما تسأل "حق عوايل ولا شباب؟"؛ لو vibe="youth" قل "حق وناسة وشباب" واسأل عن التواريخ؛ لو vibe="mixed" خل السؤال مفتوح. ممنوع تذكر كلمة "vibe" نفسها في الرد.

أسلوب الكلام الكويتي (بذكاء):
- كلمات مسموحة بحدود: "حياك الله" / "أبشر" / "من عيوني" / "تأمر أمر" / "هلا والله" / "خلني أشيك لك" / "لقيت لك" / "هذي لقطات توها نازلة" / "السوق شاد حيله" / "لو تحب" / "إذا مناسب لك" / "لو تبي رأيي".
- حد أقصى عبارة كويتية واحدة في الرد كله، ولا تكرّر نفس الافتتاحية من الرد السابق (نوّع: حياك الله → أبشر → من عيوني → تأمر أمر …).
- ممنوع العبارات التسويقية المستهلكة ("فرصة العمر"، "لا تفوتك"، "عرض حصري"، "احجز الآن").

—————————————————
بنية الرد الإلزامية (٥ أقسام بالترتيب، مختصرة جداً):
—————————————————

١) افتتاحية ودّية قصيرة (سطر واحد فقط)
- مثال: "أبشر 👌" / "خلني أوريك أفضل الخيارات الحين."

٢) أقوى خيار + سببه (٢-٣ أسطر بالكثير)
- سطر واحد للعقار #1: النوع + المنطقة + المساحة (إذا موجودة) + السعر د.ك.
- بعده مباشرة جملة "ليش ينصح فيه" مستخرجة من البيانات فقط (≤ ١٥ كلمة).
  أمثلة مقبولة فقط لو الحقائق تدعمها:
  • "سعره أقل من متوسط نفس المنطقة" (إذا labels فيها good_deal أو السعر أقل فعلياً).
  • "مساحته ${"${"}size}م² وهي من الأكبر بنفس الفئة السعرية."
  • "انحجز X مرة آخر أسبوع وهذا دليل طلب واقعي" (فقط إذا bookingsCount موجود).

٣) سياق السوق (سطر واحد، واقعي وذكي)
- اربطه بالسعر أو الفترة أو المنطقة، بشرط يكون مدعوم بأرقام أو labels أو areaProfile فعلية في البيانات:
  • "بهالفترة أسعار نفس النوع بهالمنطقة عادة أعلى شوي" (لو good_deal).
  • "السوق هالأيام على هالنوع فيه طلب، والمعروض محدود" (لو high_demand).
  • "والمنطقة [areaProfile.description]" — اقتبسه حرفياً لو الحقل موجود على العقار #1 (مثلاً "البحر فيها نظيف وممتاز للسباحة"). هذا أفضل من جملة سوق عامة لأنه شخصي للمنطقة.
  • إذا ما فيه labels ولا areaProfile: اتركه، لا تفبركه.

٤) إلحاح خفيف (اختياري، مرة واحدة لا تتكرر)
- فقط من labels الموجودة على العقار #1:
  • high_demand: "وهالنوع عادة ينحجز بسرعة بهالفترة 🔥".
  • new_listing: "وطازة على السوق، وصل حديثاً."
  • لا تكرّر الإلحاح على كل عقار، ولا تركّبه على خيار بدون label.

٥) إقفال حاسم بـ CTA — سطر واحد ينتهي بفعل أمر يقدر العميل ينفّذه فوراً
قاعدة CTA الإلزامية (Tier 2.5): كل رد لازم ينتهي بدعوة عمل واضحة فيها فعل أمر — مو سؤال عام مفتوح. ممنوع نهائياً تنتهي بـ "شنو رأيك؟" / "تبي أساعدك في شي ثاني؟" / "تبيه حق عوايل ولا شباب؟" / "أي شي ثاني؟". هالأسئلة المفتوحة تترك العميل بلا خطوة تالية وتقتل الإغلاق.
- صيغة CTA الصحيحة = "[فعل أمر] [إجراء محدد]". أمثلة قوية:
  • "اضغط #1 وأنا أأكدلك التوفر بهالفترة 👌"
  • "ابعثلي التواريخ وأنا أحجز لك مباشرة."
  • "افتح الإعلان واطلع التفاصيل، وأنا حاضر للمعاينة."
- CTA يتبع نوع الخدمة على العقار #1 (حقل serviceType):
  • sale: "اضغط على #1 وأنا أربطك بالمالك مباشرة." / "ابعث وقتك المناسب وأنا أرتب المعاينة الحين."
  • rent + (chalet أو rentalType == "daily"): "ابعثلي التواريخ وأنا أأكدلك التوفر." / "اضغط #1 وشف الصور والمميزات، وأنا حاضر أرتب الباقي."
  • rent + rentalType == "monthly": "ابعث وقتك المناسب وأنا أرتب لك المعاينة هاللي يومين."
- حتى لو العقار من فئة budget (سعر اقتصادي) — الـCTA يبقى دافع ومتحمّس، مو متردد. مثال budget: "اضغط #1 وشف السعر والصور، يستاهل."
- ممنوع تكدّس عدة أفعال أمر في سطر ("اضغط + ابعث + احجز" — اختار واحد فقط).
- لو طبيعي تسأل سؤال استشاري (مثلاً تواريخ أو ميزانية)، اقرنه بفعل أمر بنفس السطر بدل ما تخليه سؤال مفتوح: ✅ "ابعثلي بحدود ميزانيتك بالليلة وأنا أصيد لك لقطة" بدل ❌ "بحدود كم ميزانيتك؟".
- للبيت: ممنوع تسأل عن عدد الغرف. للشقة: يجوز تربطها بـCTA ("ابعثلي عدد الغرف اللي يناسبك وأنا أرتب القائمة").
- حالة "غالي / أرخص شي / في أرخص؟" بدون رقم: الرد الحتمي = "أفهمك. ابعثلي بحدود كم ميزانيتك بالليلة وأنا أصيد لك لقطة تناسبك تماماً." (CTA = "ابعثلي" — فعل أمر، مو سؤال).

—————————————————
الطول والإيقاع:
—————————————————
- الرد المثالي ٤-٧ أسطر قصيرة. ممنوع يطول.
- ممنوع قوائم مزايا طويلة، ممنوع emoji زيادة، ممنوع تكرار نفس الكلمة.

—————————————————
نوع العميل (ميتاداتا — تقرأ من آخر سطر في رسالة المستخدم):
—————————————————
يظهر أحد السطرين بالضبط: [[SEGMENT: renter]] أو [[SEGMENT: buyer]]

🔹 عندما يكون [[SEGMENT: renter]] (إيجار يومي/شهري — استخدام سكني):
- المستخدم مستأجر يبحث عن مكان مريح للسكن أو الإقامة، مو مستثمر يبحث عن عائد.
- النبرة: كلام محلي كويتي ودود يشبه المحادثة — مو تقرير ولا قائمة نقاط في الرد النهائي (انظر توجيه القرار للمستأجر في آخر البرومبت).
- ممنوع تماماً: ROI، yield، استرداد رأس المال، اتجاهات سوق عامة، "فرص استثمارية"، جمهور المستثمرين، أو مقارنة أسعار مع أحياء ما طلبها.
- ركّز على الراحة اليومية، قرب الخدمات، تفاصيل العقار من JSON، التواريخ للإيجار اليومي، وفتح الإعلان للصور.
- احذف بالكامل من ردك البند ٣ "سياق السوق" للمستأجر — حتى لو ظهرت labels بمعنى طلب عام.
- ممنوع جمل فاضية مثل "السوق مرتفع هالأيام" أو "المعروض محدود" إلا إذا كانت مربوطة ببيانات محددة على نفس الإعلان من JSON (مثل bookingsCount)، مو كلام macro عن السوق.
- سياسة المناطق + ANTI-BULLET: لا تقترح مناطق بديلة من تلقاء نفسك؛ لا تستخدم "وفي خيارات ثانية:" ولا رموز • في الرد؛ الخاتمة فقط جملة وفادة اختيارية بالصيغة المذكورة في توجيه القرار للمستأجر مع اسم المنطقة من البيانات.
- حوالي ٣–٦ أسطر قصيرة؛ الختام سؤال متابعة واحد عن أسلوب المعيشة كما في توجيه القرار للمستأجر.

🔹 عندما يكون [[SEGMENT: buyer]] (بيع / محتمل استثمار):
- اتبع الهيكل الكامل أعلاه بما فيه سياق السوق عند توفر بيانات، ومعالجة ROI_FACTS كما هي أدناه.

—————————————————
عائد الاستثمار (ROI_FACTS) — إلزامي:
—————————————————
- إذا ظهر [[SEGMENT: renter]] مع أي ROI_FACTS: تجاهل ROI_FACTS كلياً ولا تذكر عائداً أو استرداداً أو دخلاً استثمارياً.
- قد يأتيك في نهاية رسالة المستخدم بلوك بهذا الشكل: [[ROI_FACTS: yield=7.5%, annual=24000, payback=13.3y, source=owner_provided]] أو [[ROI_FACTS: null]].
- الأرقام في ROI_FACTS حسابية دقيقة. انقلها حرفياً بدون أي تعديل أو تقريب.
- لو source=owner_provided اذكر "حسب تقدير المالك" بلغة طبيعية.
- لو source=market_comparables اذكر "من مقارنة إيجارات نفس المنطقة".
- لو [[ROI_FACTS: null]] قل بالضبط: "ما عندي بيانات كافية أحسب العائد لهذا العقار بشكل دقيق." ولا تخترع أي رقم.
- ممنوع تماماً ذكر نسبة عائد أو سنوات استرداد أو دخل سنوي بدون ROI_FACTS.`;

const COMPOSE_SYSTEM_EN_CORE = `You are a top-performing Kuwaiti real-estate closer — not a search bot. Your job is to guide the user to a calm, confident decision. Never pressure; always simplify.

Closing principle (literal): DO NOT push. DO guide, suggest, reassure, simplify. Never say "book now" or any repeated imperative.

Strict — no fabrication:
- Only describe properties in the provided JSON array.
- Use ONLY fields on each object (type, size, price, areaEn, labels, bookingsCount, features, areaProfile…).
- Never invent prices, addresses, distances to the sea, phone numbers, links, or WhatsApp.
- If the array has at least one listing, NEVER say "I couldn't find anything" — present what exists as the best match right now.
- Features: if the user asks about a specific amenity (indoor pool, outdoor pool, beachfront/directly on the sea, garden, elevator, central AC, split AC, maid room, driver room, laundry room), answer strictly from listing #1's "features" object. true = available, false or missing = not available. If the flag isn't present at all, say "not specified in the data". Never confirm a feature not visible in "features".

areaProfile — curated area knowledge (when present):
- Some listings carry an areaProfile = { tier: "premium"|"mid"|"budget", vibe: "family"|"youth"|"mixed", description: "short note about the area" }.
- This field is OPTIONAL — not every listing has it. If listing #1 has it, use it; if not, never invent it.
- description: quote it verbatim (no edits) as a natural market-context line tied to listing #1, ONCE only — e.g. "and the area itself — [description]". Don't carry it over to other listings that don't have a profile.
- tier: use it INTERNALLY to set tone (premium → "high-end / refined"; mid → "strong pick"; budget → "value-friendly"). NEVER name the words tier / premium / mid / budget in the reply.
- vibe: if vibe="family" close confidently with "great for families" instead of asking "family or friends?"; if vibe="youth" lean into "great for a friends getaway" and ask about dates; if vibe="mixed" keep the question open. NEVER name the word "vibe" itself.

Voice:
- Warm, confident, professional. Avoid tired sales phrases ("once in a lifetime", "don't miss out", "exclusive deal", "book now").
- Do NOT repeat the same opener from your previous reply (you receive the last turns as context).

—————————————————
Mandatory reply structure (5 blocks, tight):
—————————————————

1) Short friendly start (one line).
   e.g. "Here's what I'd recommend." / "Quick rundown for you:"

2) Strongest option + reason (2–3 lines max).
   - One line for listing #1: type + area + size (if present) + price in KWD.
   - Immediately after, one "why this one" line drawn from data only (≤ 15 words).
     Valid examples only when facts support them:
     • "priced below the area average" (only if good_deal label or numerically below).
     • "${"${"}size} m² — among the largest in this price tier."
     • "booked X times in the past week — real demand signal" (only if bookingsCount exists).

3) Market context (ONE line, data-grounded).
   Tie it to real price / labels / booking data / areaProfile:
   • "Prices for this type in this area tend to run higher in this window" (only if good_deal).
   • "This type is seeing real pull right now, and supply is tight" (only if high_demand).
   • "and the area itself — [areaProfile.description]" — quote verbatim when listing #1 has the field. Prefer this over a generic market line because it's specific to the location.
   • If labels AND areaProfile are both empty: skip this block entirely — never fabricate market context.

4) Light urgency (optional, once only).
   Only if listing #1 carries the label:
   • high_demand → "this type tends to book fast in this window 🔥"
   • new_listing → "freshly listed."
   Never stack urgency, never attach it to an option without the label.

5) Decisive close — one line ending with a concrete CTA the user can act on RIGHT NOW.
   MANDATORY CTA RULE (Tier 2.5): every reply MUST end with an action-oriented call to action — never a vague open question. Endings like "what do you think?" / "anything else?" / "family or friends?" are FORBIDDEN. They strand the customer with no next step and kill the close.
   - Correct CTA shape = "[action verb] [specific action]". Strong examples:
     • "Tap #1 and I'll lock in availability for those dates 👌"
     • "Send me the dates and I'll book it directly."
     • "Open the listing for the full details — I'm ready to set up the viewing."
   - CTA follows listing #1's 'serviceType':
     • sale: "Tap #1 and I'll connect you with the owner directly." / "Send me a time that works and I'll set up the viewing."
     • rent + (chalet OR rentalType == "daily"): "Send me the dates and I'll confirm availability." / "Tap #1 to see the photos — I'm here to handle the rest."
     • rent + rentalType == "monthly": "Send me a time and I'll arrange the viewing this week."
   - Even for budget-tier listings, keep the CTA energetic — never timid. Example budget close: "Tap #1 — the price-to-value here is real."
   - Never stack multiple action verbs in one line ("tap + send + book" — pick ONE).
   - When a consultative question is natural (dates, budget, etc.), pair it with an action verb instead of leaving it open: ✅ "Send me your nightly budget and I'll pull a real match." NOT ❌ "What's your nightly budget?".
   - House: do NOT ask about bedrooms. Apartment: pair the bedroom question with a CTA ("Send me your bedroom count and I'll line up the shortlist").
   - Pushback case ("too expensive" / "any cheaper?" with no number): the mandated reply is "Got it — send me your nightly budget and I'll find a real match for you." (CTA = "send me" — an action verb, not an open question).

—————————————————
Length:
—————————————————
- Ideal reply: 4–7 short lines. No feature-lists, no emoji clutter, no repetition.

—————————————————
Customer segment metadata (read from the LAST line of the user message):
—————————————————
You will see exactly one line: [[SEGMENT: renter]] OR [[SEGMENT: buyer]]

🔹 When [[SEGMENT: renter]] (daily/monthly rent — residential stay):
- The user is renting for comfort/lifestyle — NOT investing.
- Tone: friendly local Kuwaiti hospitality — chatty prose, not a fact dump or bullet-style reply (see renter Decision guidance at the end of this prompt).
- NEVER mention: ROI, yield, payback, generic "market trends", "investment opportunities", investor audiences, or comparing prices with districts they did not request.
- Focus on everyday convenience, nearby services, listing facts from JSON, dates for daily stays, and tapping through for photos/details.
- OMIT block (3) "Market context" entirely for renters.
- Avoid hollow phrases like "the market is high these days" or "limited availability" unless tied to concrete JSON on THIS listing (e.g. bookingsCount), not vague macro talk.
- Areas policy + ANTI-BULLET: do NOT proactively suggest other districts; never use "Other options:" or • bullets in the reply; optional closing line exactly as in renter Decision guidance using listing #1's areaEn/areaAr.
- ~3–6 short lines; close with one lifestyle follow-up as specified in renter Decision guidance.

🔹 When [[SEGMENT: buyer]]:
- Follow the full structure above including market context when grounded, and ROI_FACTS handling below.

—————————————————
ROI / yield facts (mandatory handling):
—————————————————
- If [[SEGMENT: renter]] appears with ROI_FACTS: ignore ROI_FACTS completely — no yields, payback, or investment income.
- The user message may end with a block like [[ROI_FACTS: yield=7.5%, annual=24000, payback=13.3y, source=owner_provided]] or [[ROI_FACTS: null]].
- ROI_FACTS numbers are computed deterministically — quote them verbatim, never change or round.
- source=owner_provided → phrase it as "based on the owner's estimate".
- source=market_comparables → phrase it as "based on comparable rentals in the same area".
- If [[ROI_FACTS: null]] say exactly: "I don't have enough data to calculate a reliable yield for this listing." NEVER guess a yield, annual income, or payback period.
- Without a ROI_FACTS block, do NOT mention yield / payback / annual income numbers at all.`;

function buildComposeSystemContent(locale: string, segment: ComposeSegment): string {
  const base = locale === "ar" ? COMPOSE_SYSTEM_AR_CORE : COMPOSE_SYSTEM_EN_CORE;
  return base + buildComposeDecisionGuidance(segment, locale);
}

// ---------------------------------------------------------------------------
// Feature answer composer
// ---------------------------------------------------------------------------

/**
 * Maps a feature key to its bilingual display label. `hasPoolAny` is a
 * virtual key used when the user didn't qualify indoor vs outdoor — we
 * expand it to both real flags when resolving the answer.
 */
const FEATURE_LABELS_AR: Record<Exclude<AskedFeatureKey, "hasPoolAny">, string> = {
  hasPoolIndoor: "مسبح داخلي",
  hasPoolOutdoor: "مسبح خارجي",
  isBeachfront: "على البحر مباشرة",
  hasGarden: "حديقة",
  hasElevator: "أصانصير",
  hasCentralAC: "تكييف مركزي",
  hasSplitAC: "تكييف وحدات",
  hasMaidRoom: "غرفة خادمة",
  hasDriverRoom: "غرفة سائق",
  hasLaundryRoom: "غرفة غسيل",
};
const FEATURE_LABELS_EN: Record<Exclude<AskedFeatureKey, "hasPoolAny">, string> = {
  hasPoolIndoor: "an indoor pool",
  hasPoolOutdoor: "an outdoor pool",
  isBeachfront: "directly beachfront",
  hasGarden: "a garden",
  hasElevator: "an elevator",
  hasCentralAC: "central AC",
  hasSplitAC: "split AC",
  hasMaidRoom: "a maid room",
  hasDriverRoom: "a driver room",
  hasLaundryRoom: "a laundry room",
};

function readFeatureFlag(
  features: Record<string, unknown> | undefined,
  key: Exclude<AskedFeatureKey, "hasPoolAny">
): boolean {
  return !!features && features[key] === true;
}

/**
 * Build a deterministic reply to a feature question ("فيه مسبح خارجي؟").
 * Answers strictly from the listing's `features` map — no fabrication.
 * Returns null when we can't locate a usable listing (caller falls back
 * to the normal LLM compose path).
 */
function composeFeatureAnswer(
  listing: Record<string, unknown> | undefined,
  asked: AskedFeatureKey[],
  locale: "ar" | "en"
): string | null {
  if (!listing) return null;
  const features =
    typeof listing.features === "object" && listing.features !== null
      ? (listing.features as Record<string, unknown>)
      : undefined;
  if (!features) return null;

  const area =
    locale === "ar"
      ? String(listing.areaAr ?? listing.areaEn ?? "").trim()
      : String(listing.areaEn ?? listing.areaAr ?? "").trim();
  const typeAr = String(listing.type ?? "").trim();

  // Expand the virtual "hasPoolAny" into the two real keys so the answer
  // can cover both variants when the user asked a generic "فيه مسبح؟".
  const concrete: Exclude<AskedFeatureKey, "hasPoolAny">[] = [];
  for (const k of asked) {
    if (k === "hasPoolAny") {
      if (!concrete.includes("hasPoolIndoor")) concrete.push("hasPoolIndoor");
      if (!concrete.includes("hasPoolOutdoor")) concrete.push("hasPoolOutdoor");
    } else if (!concrete.includes(k)) {
      concrete.push(k);
    }
  }
  if (concrete.length === 0) return null;

  const lines: string[] = [];
  const header =
    locale === "ar"
      ? area
        ? `عن العقار في ${area}:`
        : "عن هذا العقار:"
      : area
        ? `About the listing in ${area}:`
        : "About this listing:";
  lines.push(header);

  for (const key of concrete) {
    const has = readFeatureFlag(features, key);
    const label = locale === "ar" ? FEATURE_LABELS_AR[key] : FEATURE_LABELS_EN[key];
    if (locale === "ar") {
      lines.push(has ? `• ${label}: إي، متوفر 👌` : `• ${label}: لا، مو متوفر.`);
    } else {
      lines.push(has ? `• ${label}: yes, available 👌` : `• ${label}: no, not available.`);
    }
  }

  // Soft closer keeps the sales tone without inventing new facts.
  if (locale === "ar") {
    const closer = typeAr
      ? "لو تبي أعطيك نظرة أوضح على العقار أو أرتب لك الحجز، قل لي 👌"
      : "إذا تبي تفاصيل أكثر أو ترتيب الحجز، قل لي 👌";
    lines.push(closer);
  } else {
    lines.push("Want me to pull up more details or set up the booking?");
  }

  return lines.join("\n");
}

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

/**
 * Warm, type-aware clarifying question for when the customer hasn't told us
 * the area yet. Keeps a single short question per ANALYZE_SYSTEM rule 3 —
 * never a templated "which area?" wall.
 */
function buildAreaClarifyQuestion(rawType: string, locale: "ar" | "en"): string {
  const t = (rawType || "").trim().toLowerCase();
  if (locale === "ar") {
    if (t === "chalet")
      // Chalets rent BOTH daily (weekend) and monthly (long-term) at very
      // different prices, so we ask the cadence up front instead of guessing.
      return "حياك الله 👌 تبي شاليه بأي منطقة، ويومي (بالليلة) ولا شهري؟";
    if (t === "apartment")
      return "حياك الله 👌 تبي شقة بأي منطقة، وميزانيتك تقريباً كم؟";
    if (t === "house" || t === "villa")
      return "حياك الله 👌 تبي بأي منطقة، وميزانيتك تقريباً كم؟";
    if (t === "land")
      return "حياك الله 👌 تبي أرض بأي منطقة، وكم المساحة اللي تبيها؟";
    if (t === "office" || t === "shop")
      return "حياك الله 👌 بأي منطقة تبحث، وكم الميزانية تقريباً؟";
    return "حياك الله 👌 تبي شاليه، شقة، ولا بيت؟ وبأي منطقة؟";
  }
  if (t === "chalet")
    return "Welcome 👌 which area, and is it a daily (per-night) stay or a monthly rental?";
  if (t === "apartment")
    return "Welcome 👌 which area are you after, and roughly what's your budget?";
  if (t === "house" || t === "villa")
    return "Welcome 👌 which area are you after, and roughly what's your budget?";
  if (t === "land")
    return "Welcome 👌 which area are you after, and what size are you looking for?";
  if (t === "office" || t === "shop")
    return "Welcome 👌 which area are you after, and what's your budget?";
  return "Welcome 👌 chalet, apartment, or house? And which area?";
}

/**
 * Warm clarifying question fired AFTER we already know the customer wants a
 * chalet for rent in a specific area but the rental cadence is still missing.
 * Daily chalets are weekend stays priced per night; monthly chalets are
 * long-term leases priced per month — completely different listings, so we
 * must ask before searching.
 */
function buildChaletCadenceClarifyQuestion(locale: "ar" | "en"): string {
  if (locale === "ar") {
    return "أبشر 👌 الشاليه يومي (بالليلة) ولا شهري؟ كل وحدة لها أسعار وخيارات تختلف عن الثانية.";
  }
  return "Got it 👌 daily (per-night) stay or a monthly rental? They're priced and listed very differently.";
}

/**
 * Tier 2 — attach the curated [AreaProfile] to each listing before sending it
 * to the compose LLM. Two reasons this lives here (rather than mutating the
 * listing in-place upstream):
 *
 *   1) The `top3Results` returned to the client must stay clean — the Flutter
 *      side has no use for `tier`/`vibe` and shouldn't pay for the bytes.
 *      We build a *new* array for the prompt only.
 *   2) Curation is sparse on purpose: only seeded slugs (see AREA_INTELLIGENCE)
 *      get a profile; everything else is left as-is so the LLM falls back to
 *      its existing data-grounded behavior. We never default-fill a tier or
 *      vibe — guessing degrades the broker persona we just fought to install.
 *
 * Each enriched entry preserves all original fields and adds:
 *   areaProfile?: { tier, vibe, description }
 */
function enrichListingsWithAreaProfile(
  listings: Record<string, unknown>[]
): Record<string, unknown>[] {
  if (!Array.isArray(listings) || listings.length === 0) return listings;
  return listings.map((row) => {
    const code =
      typeof row?.areaCode === "string"
        ? (row.areaCode as string).trim().toLowerCase()
        : "";
    if (!code) return row;
    const profile: AreaProfile | undefined = AREA_INTELLIGENCE[code];
    if (!profile) return row;
    return { ...row, areaProfile: profile };
  });
}

// ---------------------------------------------------------------------------
// Pivot fetcher — when the customer's requested area returns nothing, we
// pull listings from the curated alternative slug surfaced by
// [findAlternativeArea]. The query is intentionally minimal:
//
//   • approved == true              (publishable)
//   • hiddenFromPublic == false     (lifecycle visibility)
//   • areaCode == altSlug           (the alt itself; cluster expansion is
//                                    deliberately skipped — the alt is
//                                    already a single canonical slug)
//   • serviceType == ...            (only when known — preserves rent/sale)
//   • type == ...                   (only when known — preserves chalet/etc)
//
// Why we DON'T preserve `rentalType` and `budget`:
//   • `rentalType` would over-filter when many older docs lack the field
//     (same trade-off the Dart `_chaletMarketplaceQuery` makes — see the
//     comment there). The pivot's job is to surface SOMETHING in the alt
//     area; daily-vs-monthly nuance is a Tier 3 polish.
//   • `budget` filtering on the alt would frequently produce a second empty
//     query and we'd end up at NO_RESULTS_AR anyway. The customer already
//     accepted "different area" by reaching this fallback; they'll accept
//     a slightly different price band too.
//
// Returns up to [limit] raw documents (not yet ranked / labeled). The caller
// runs them through `computeRankedTop3WithLabels` for parity with the
// normal compose flow.
// ---------------------------------------------------------------------------
async function fetchPivotChalets(
  altSlug: string,
  filters: { serviceType?: string; propertyType?: string },
  limit = 12
): Promise<Record<string, unknown>[]> {
  if (!altSlug) return [];
  let q: admin.firestore.Query = db
    .collection("properties")
    .where("approved", "==", true)
    .where("hiddenFromPublic", "==", false)
    .where("areaCode", "==", altSlug);

  const svc = (filters.serviceType ?? "").trim();
  if (svc) q = q.where("serviceType", "==", svc);
  const ptype = (filters.propertyType ?? "").trim();
  if (ptype) q = q.where("type", "==", ptype);

  try {
    const snap = await q.orderBy("createdAt", "desc").limit(limit).get();
    return snap.docs.map((d) => ({ id: d.id, ...(d.data() as Record<string, unknown>) }));
  } catch (err) {
    // Composite-index miss is the most likely failure here. Log and return
    // empty so the caller falls through to NO_RESULTS_AR — the pivot is a
    // best-effort enhancement, not a hard requirement.
    console.error("Pivot fetch failed:", err);
    return [];
  }
}

/**
 * Builds the deterministic Pivot intro line. We render this server-side
 * (NOT via the LLM) so the wording is exactly under product control —
 * the customer sees the same warm, on-brand copy every single time.
 *
 * The match-kind drives the connecting phrase:
 *   • exact     → "بنفس الجو" / "with the same vibe"
 *   • same_tier → "بنفس الفئة" / "in the same tier"
 *   • same_vibe → "بنفس الذوق" / "with the same vibe"
 *   • same_kind → "خيار قريب" / "a close alternative"
 *
 * Tier label → warm Kuwaiti adjective (premium / mid / budget). We never
 * print the literal "tier" / "premium" / "vibe" tokens — those are internal.
 */
function buildPivotIntro(
  locale: "ar" | "en",
  requestedAreaLabel: string,
  altLabel: string,
  alt: AreaAlternative
): string {
  const { profile, matchKind } = alt;
  if (locale === "ar") {
    const tierLabel =
      profile.tier === "premium"
        ? "خيار راقي"
        : profile.tier === "budget"
          ? "خيار اقتصادي"
          : "خيار قوي";
    const matchLabel =
      matchKind === "exact"
        ? "بنفس الجو"
        : matchKind === "same_tier"
          ? "بنفس الفئة"
          : matchKind === "same_vibe"
            ? "بنفس الذوق"
            : "خيار قريب";
    return `للأسف ما نزل شي في ${requestedAreaLabel} هاللحين، بس ${altLabel} ${tierLabel} ${matchLabel} — ${profile.description} شوف هاللقطات بدلاً 👇`;
  }
  const tierLabel =
    profile.tier === "premium"
      ? "a high-end pick"
      : profile.tier === "budget"
        ? "a value-friendly pick"
        : "a strong pick";
  const matchLabel =
    matchKind === "exact"
      ? "with the same vibe"
      : matchKind === "same_tier"
        ? "in the same tier"
        : matchKind === "same_vibe"
          ? "with a similar feel"
          : "a close alternative";
  return `Nothing's listed in ${requestedAreaLabel} right now — but ${altLabel} is ${tierLabel} ${matchLabel}: ${profile.description} Check these out instead 👇`;
}

/** Confirmed bookings in rolling window at or above this count get the high-demand line + label. */
const TOP_DEMAND_HIGH_BOOKINGS = 5;
/** Fetch extra chalet candidates so post-filters (e.g. budget) still allow ranking + fallback. */
const TOP_DEMAND_FETCH_POOL = 48;
const TOP_DEMAND_REPLY_CAP = 10;

/**
 * @deprecated Retained for potential reactivation (e.g. admin dashboard).
 * The AI chat no longer dispatches into this branch — it always runs a
 * customer-matched search based on the user's own specs.
 */
export function detectTopDemandChaletsIntent(message: string): boolean {
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
 *
 * Date-aware gating (when `availability` is supplied): any chalet that is
 * reserved (`confirmed` or live `pending_payment`) or has a `blocked_dates`
 * overlap for `[startDate, endDate)` is skipped. This turns the "most-demanded
 * chalets" feed from a pure demand signal into an availability-aware feed,
 * eliminating the pre-existing contradiction where a fully-booked chalet would
 * be ranked first *because* it was booked.
 *
 * When `availability` is not supplied, behavior is unchanged (backward-compat).
 */
async function fetchTopDemandChaletsForAgent(
  availability?: {
    start: admin.firestore.Timestamp;
    end: admin.firestore.Timestamp;
  } | null
): Promise<TopDemandAgentRow[]> {
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

    // Date-aware gate: reuse the authoritative `isDateRangeAvailable` from
    // `chalet_booking.ts` — it already consults `bookings` + `blocked_dates`
    // and honors the pending_payment hold. We only hit it when the user
    // supplied a travel window on this turn.
    if (availability) {
      try {
        const ok = await isDateRangeAvailable(
          propertyId,
          availability.start,
          availability.end
        );
        if (!ok) continue;
      } catch (err) {
        // Fail-closed on availability errors: if we cannot verify, skip this
        // property from the "top demand" list rather than risk surfacing a
        // booked chalet. The fallback behavior (no date context) is the
        // non-availability branch that retains pre-existing behavior.
        console.warn({
          tag: "top_demand.availability_error",
          propertyId,
          message: err instanceof Error ? err.message : String(err),
        });
        continue;
      }
    }

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
      // Amenities / feature flags — forwarded so the LLM can answer
      // feature questions like "فيه مسبح خارجي؟" or "على البحر مباشرة؟".
      features: {
        hasElevator: pd.hasElevator === true,
        hasCentralAC: pd.hasCentralAC === true,
        hasSplitAC: pd.hasSplitAC === true,
        hasMaidRoom: pd.hasMaidRoom === true,
        hasDriverRoom: pd.hasDriverRoom === true,
        hasLaundryRoom: pd.hasLaundryRoom === true,
        hasGarden: pd.hasGarden === true,
        hasPoolIndoor: pd.hasPoolIndoor === true,
        hasPoolOutdoor: pd.hasPoolOutdoor === true,
        isBeachfront: pd.isBeachfront === true,
      },
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

/**
 * @deprecated Kept so the "trending chalets" feed stays available to other
 * callers (e.g. `get_top_demand_chalets.ts` / admin surfaces). The AI chat
 * intentionally no longer composes through this path; see the notes on
 * `detectTopDemandChaletsIntent`.
 */
export async function buildTopDemandChaletsCompose(
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
  // Pull the Date Intelligence Layer triple from the incoming filters. If the
  // client didn't push dates into `currentFilters` yet, also try to extract a
  // range from this turn's raw message (e.g. "اكثر الشاليهات طلباً من 27 الى
  // 29"). When both sources exist, filter values win (the client applied them
  // intentionally). If a valid `[startDate, endDate)` window is present, we
  // forward it to the top-demand fetch so booked chalets get filtered out
  // upstream.
  const filtersForDates = (opts?.currentFilters ?? {}) as Record<string, unknown>;
  let startTs = parseIsoToTimestamp(filtersForDates.startDate);
  let endTs = parseIsoToTimestamp(filtersForDates.endDate);
  if ((!startTs || !endTs) && opts?.rawMessage) {
    const inline = extractDateRangeFromText(opts.rawMessage);
    if (inline) {
      startTs = parseIsoToTimestamp(inline.startDate);
      endTs = parseIsoToTimestamp(inline.endDate);
    }
  }
  const availability =
    startTs && endTs && startTs.toMillis() < endTs.toMillis()
      ? { start: startTs, end: endTs }
      : null;
  const rows = (await fetchTopDemandChaletsForAgent(availability)).filter((r) =>
    topDemandRowPriceOk(r)
  );
  if (rows.length === 0) {
    return {
      reply:
        locale === "ar"
          ? "بهالفترة الشاليهات المطلوبة شبه محجوزة بالكامل. قل لي منطقتك المفضلة أو عدد الليالي وخلني أطلع لك أقرب خيار متاح 👌"
          : "Chalets are nearly fully booked in this window. Tell me your preferred area or number of nights and I'll surface the closest available option.",
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
      lines.push("مافي مطابق تماماً لنفس المواصفات، بس لقيت لك أقرب الخيارات ومرتبة حسب الطلب 👇", "");
    } else {
      lines.push(
        "No exact match on every spec, but these are the closest options — ranked by booking demand 👇",
        ""
      );
    }
  } else if (hasPersonalization) {
    if (locale === "ar") {
      lines.push("أبشر، هذي أكثر الشاليهات طلباً وتناسب طلبك 👇", "");
    } else {
      lines.push("Here are the most in-demand chalets that fit what you're after 👇", "");
    }
  } else {
    if (locale === "ar") {
      lines.push("هذي أكثر الشاليهات طلباً بالسوق حالياً 👇", "");
    } else {
      lines.push("These are the chalets booked the most right now 👇", "");
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
        `السعر: ${r.price} د.ك — انحجز ${r.bookingsCount} مرة بآخر أسبوع`
      );
      if (showNightsBreakdown) {
        const total = r.price * userNights!;
        lines.push(`لإقامة ${userNights} ليالي: ${total} د.ك`);
      }
      if (budgetReasonAr != null) lines.push(`✅ ${budgetReasonAr}`);
      if (areaMatched) lines.push("📍 قريب من منطقتك المفضلة");
      if (high) lines.push("🔥 عليه طلب عالي — عادةً ينحجز بسرعة");
      lines.push("");
    } else {
      lines.push(
        `${idx}) ${r.title}`,
        `Price: KWD ${r.price} — booked ${r.bookingsCount} times this past week`
      );
      if (showNightsBreakdown) {
        const total = r.price * userNights!;
        lines.push(`For ${userNights} nights: KWD ${total}`);
      }
      if (budgetReasonEn != null) lines.push(`✅ ${budgetReasonEn}`);
      if (areaMatched) lines.push("📍 Close to your preferred area");
      if (high) lines.push("🔥 High demand — tends to book fast");
      lines.push("");
    }
  }

  if (locale === "ar") {
    lines.push("اضغط على أي واحد منهم تطّلع على الصور والتفاصيل. تبي أضيّق لك أكثر بمنطقة أو ميزانية؟");
  } else {
    lines.push("Tap any of them to see photos and full details. Want me to narrow it down by area or budget?");
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
  // `let` (not `const`) because the Tier 2.5 Pivot may swap this with the
  // alternative-area listings when the customer's requested area returns
  // nothing. See the pivot block before the 0-results fallback below.
  let top3Results = Array.isArray(data.top3Results) ? (data.top3Results as Record<string, unknown>[]) : [];
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
  // Top-demand compose is intentionally disabled on the chat surface — the
  // AI is required to answer with the user's own specs (area, budget,
  // dates, features), not a generic popularity feed. Any stale client that
  // still tags `intent: "top_demand_chalets"` falls through to the normal
  // compose path below so the user always lands on matched results.
  if (intentFromClient === TOP_DEMAND_INTENT) {
    console.info(
      JSON.stringify({
        tag: "top_demand_chalets.compose_deprecated",
        note: "falling through to normal compose",
      })
    );
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

  // ---------------------------------------------------------------------
  // Tier 2.5 PIVOT — dead-end recovery.
  //
  // When the customer's strict search returned zero rows AND the requested
  // area is one we've curated in [AREA_INTELLIGENCE], we don't say "ما لقيت
  // شي" and walk away. We pivot like a real dallal would:
  //
  //   1. Resolve the requested area's profile (tier + vibe).
  //   2. Find the closest curated alternative — same tier+vibe ideally,
  //      else same tier, else same vibe, else any same-kind area.
  //   3. Fetch real listings from the alt area (server-side Firestore
  //      query mirroring the chalet branch) preserving the original
  //      serviceType + propertyType so we don't suggest the wrong product.
  //   4. If the alt query yielded anything, swap [top3Results] with its
  //      ranked top-3 and PREPEND a deterministic, on-brand pivot intro
  //      to the LLM-composed reply.
  //
  // Three guardrails:
  //   • [pivotIntro] is rendered server-side, not by the LLM, so the
  //     wording is exactly what product approved.
  //   • Same-kind matching ([findAlternativeArea] uses [isChaletBeltArea])
  //     prevents nonsense pivots like "Bneider chalet → Qadisiya villa".
  //   • If alt also returns zero rows we fall through to the existing
  //     NO_RESULTS_AR — the pivot is a best-effort enhancement.
  // ---------------------------------------------------------------------
  let pivotIntro = "";
  let effectiveAreaCode = areaCode;
  let effectiveAreaLabel = requestedAreaLabel;
  if (top3Results.length === 0 && areaCode) {
    const alt = findAlternativeArea(areaCode);
    if (alt) {
      const altRaw = await fetchPivotChalets(alt.slug, {
        serviceType,
        propertyType,
      });
      if (altRaw.length > 0) {
        const altRanked = await computeRankedTop3WithLabels(
          altRaw,
          alt.slug,
          [],
          userBudget ?? null
        );
        if (altRanked.length > 0) {
          const altLabel =
            (altRanked[0]?.areaAr as string) ||
            (altRanked[0]?.areaEn as string) ||
            alt.slug;
          const reqLabel =
            requestedAreaLabel ||
            areaCode ||
            (locale === "ar" ? "هذي المنطقة" : "this area");
          pivotIntro = buildPivotIntro(locale, reqLabel, altLabel, alt);
          top3Results = altRanked;
          effectiveAreaCode = alt.slug;
          effectiveAreaLabel = altLabel;
          console.info(
            JSON.stringify({
              tag: "pivot.applied",
              from: areaCode,
              to: alt.slug,
              matchKind: alt.matchKind,
              altCount: altRanked.length,
            })
          );
        }
      }
    }
  }

  // Recompute suggestions AFTER the pivot so the chips are anchored on the
  // alt area when applicable (e.g. "بحث في رواضي شاليه شهري" should chip
  // around Rawda, not the empty Bneider).
  const suggestions = buildSmartSuggestions({
    area: effectiveAreaCode || undefined,
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

  // `userAskedForMore` describes the original (pre-pivot) search. Once a
  // pivot has fired we are no longer in the "only one match found" UX —
  // we're explicitly showing alternatives — so the SINGLE_RESULT short-
  // circuit must NOT swallow the pivot intro.
  if (top3Results.length === 1 && userAskedForMore && !pivotIntro) {
    const reply = locale === "ar" ? SINGLE_RESULT_ASKED_MORE_AR : SINGLE_RESULT_ASKED_MORE_EN;
    return { reply: appendSuggestionsToReply(reply, suggestions, locale) };
  }

  // ---------------------------------------------------------------------
  // Feature Q&A short-circuit.
  //   The user is asking about a concrete amenity on an already-shown
  //   listing ("فيه مسبح خارجي؟", "is it beachfront?"). We answer straight
  //   from the first listing's `features` map instead of round-tripping
  //   to the LLM — this is faster, deterministic, and never hallucinates.
  // ---------------------------------------------------------------------
  if (rawMessage) {
    const askedFeatures = detectAskedFeatures(rawMessage);
    if (askedFeatures.length > 0 && isFeatureQuestion(rawMessage, askedFeatures)) {
      const primary = top3Results[0];
      const featureAnswer = composeFeatureAnswer(primary, askedFeatures, locale);
      if (featureAnswer) {
        return {
          reply: appendSuggestionsToReply(featureAnswer, suggestions, locale),
          results: top3Results,
        };
      }
    }
  }

  const areaLabel =
    effectiveAreaLabel ||
    (top3Results[0]?.areaAr as string) ||
    (top3Results[0]?.areaEn as string) ||
    effectiveAreaCode ||
    (locale === "ar" ? "هذه المنطقة" : "this area");

  // Use [effectiveAreaCode] (post-pivot) so insights / market-signal /
  // labeling all run against the area whose listings we're actually
  // showing. Otherwise after a pivot we'd be quoting Bneider market data
  // alongside Rawda listings — instant credibility loss.
  const context: SearchContext = {
    areaCode: effectiveAreaCode || undefined,
    propertyType: propertyType || undefined,
    serviceType: serviceType || undefined,
    budget: userBudget,
  };

  const composeSegment = resolveComposeSegment(serviceType, top3Results[0]);

  try {
    const insights = await buildInsights({
      context,
      areaLabel,
      topResults: top3Results,
      rawMessage: rawMessage || undefined,
      locale,
      db,
      segment: composeSegment,
    });

    // Inject deterministic ROI facts when the user is asking an investment
    // question about a sale listing. The LLM is instructed (in the system
    // prompt) to quote these numbers verbatim and — when the block is
    // `ROI_FACTS: null` — refuse to guess yields. This is the single most
    // important guardrail for investment advice.
    let roiFactsText = "";
    try {
      const primary = top3Results[0] || {};
      const primaryService = String(primary.serviceType || "").toLowerCase();
      const primaryId =
        typeof primary.id === "string" ? primary.id : String(primary.id || "");
      if (
        composeSegment === "buyer" &&
        rawMessage &&
        primaryId &&
        primaryService === "sale" &&
        isInvestmentQuestion(rawMessage)
      ) {
        const roi = await computeRoiForProperty(primaryId);
        if (roi) {
          const f = roiToFactsBlock(roi);
          roiFactsText = `\n\n[[ROI_FACTS: yield=${f.yield}, annual=${f.annual}, payback=${f.payback}, source=${f.source}${
            f.sampleSize ? `, sample=${f.sampleSize}` : ""
          }]]`;
        } else {
          roiFactsText = "\n\n[[ROI_FACTS: null]]";
        }
      }
    } catch (err) {
      console.error("ROI inject failed (non-fatal):", err);
    }

    const openai = new OpenAI({ apiKey });
    const systemContent = buildComposeSystemContent(locale, composeSegment);
    // Enrich listings with curated area profile (tier/vibe/description) so the
    // compose LLM can speak like a Kuwaiti dallal — quoting the area's vibe
    // verbatim and matching the closing question to the customer's likely
    // social context. The original `top3Results` (without `areaProfile`) is
    // still what we return to the client below.
    const top3ForCompose = enrichListingsWithAreaProfile(top3Results);
    const completion = await openai.chat.completions.create({
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: systemContent },
        {
          role: "user",
          content:
            JSON.stringify(top3ForCompose) +
            `\n\n[[SEGMENT: ${composeSegment}]]` +
            roiFactsText,
        },
      ],
      max_tokens: 300,
    });
    const llmReply =
      completion.choices?.[0]?.message?.content?.trim() ||
      (locale === "ar" ? "لقيت لك خيارات. ميزانيتك كم؟" : "Found some options. What's your budget?");

    // Prepend the deterministic Pivot intro (if any). The intro frames WHY
    // the customer is seeing alt-area listings; the LLM then continues
    // with the normal three-listing pitch as if the alt area were the
    // requested one. The blank line keeps the visual hierarchy clean.
    const mainReplyBody = pivotIntro
      ? `${pivotIntro}\n\n${llmReply}`
      : llmReply;

    const payload = composeAssistantResponse({
      locale,
      mainReplyBody,
      results: top3Results,
      insights,
      suggestions,
      segment: composeSegment,
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

    // High-intent booking shortcut. We short-circuit the LLM round-trip with
    // a warm canned reply because this is the moment to CONFIRM, not to keep
    // searching. The client exposes the "tap listing → book" flow, so the
    // reply points the user there instead of inventing a booking action.
    if (detectBookingIntent(rawMessage)) {
      return {
        intent: "booking_intent",
        params_patch: {},
        reset_filters: false,
        is_complete: true,
        clarifying_questions: [],
        greeting_reply:
          locale === "ar"
            ? "أبشر 👌 خلني أرتب لك الحجز على طول — اختر العقار من الخيارات اللي عرضتها لك وادخل على صفحة التفاصيل، أقدر أكمل معك خطوات الحجز من هناك. إذا ما اتفقت على عقار بعد، قل لي تاريخ الحجز والمنطقة وأجهّز لك أفضل خيار متاح."
            : "Perfect 👌 let's lock it in. Open the listing from the options I showed you and tap through to the details page — I can walk you through the booking steps from there. If you haven't picked one yet, just tell me your dates and area and I'll line up the best match.",
      };
    }

    // Undecided / hesitation — reassure without pressure. Same pattern as
    // greeting: warm canned reply, no search flow, no filter changes.
    if (detectHesitationIntent(rawMessage)) {
      return {
        intent: "hesitation",
        params_patch: {},
        reset_filters: false,
        is_complete: true,
        clarifying_questions: [],
        greeting_reply:
          locale === "ar"
            ? "خذ راحتك 👌 ما فيه استعجال. إذا حاب أرتب لك أفضل خيار حسب ميزانيتك أو التواريخ اللي تناسبك قل لي، وإلا أقدر أتابع لك أول ما ينزل شي مناسب."
            : "Take your time 👌 no rush. If you'd like, I can line up the best option for your budget or dates — just say the word. Otherwise I can keep an eye out and ping you when a strong match is listed.",
      };
    }

    // NOTE: the "most in-demand chalets" shortcut used to fire here, but
    // product decided the AI chat should always serve the user's concrete
    // specs (area, budget, dates, features) instead of a one-size-fits-all
    // popularity feed. If the user literally asks for "الأكثر طلباً"، we
    // fall through to the normal LLM analyze pass, which asks them for
    // the missing specs and then runs a targeted search.

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

      // Defensive sanitization for LLM-emitted areaCodes. The model occasionally
      // tries to "help" by joining typed area names into a single slug
      // ("khairan_benider_jaleea") or by inventing English slugs that don't
      // exist in the database. We only accept entries that match a known
      // canonical slug from KUWAIT_AREAS (its set of values). If anything is
      // unknown we drop the whole array and let the deterministic multi-area
      // parser (extractAllAreaCodesFromText) populate it later in the flow.
      if (Array.isArray(paramsPatch.areaCodes)) {
        const knownSlugs = new Set(Object.values(KUWAIT_AREAS));
        const cleaned = (paramsPatch.areaCodes as unknown[])
          .map((v) => (typeof v === "string" ? v.trim().toLowerCase() : ""))
          .filter((v) => v.length > 0 && knownSlugs.has(v));
        const distinct = Array.from(new Set(cleaned));
        if (distinct.length >= 2) {
          paramsPatch.areaCodes = distinct;
        } else {
          delete paramsPatch.areaCodes;
        }
      }

      const kuwaiti = normalizeKuwaitiIntent(rawMessage);
      if (kuwaiti.propertyType && (paramsPatch.type == null || paramsPatch.type === ""))
        paramsPatch.type = kuwaiti.propertyType;
      if (kuwaiti.serviceType && (paramsPatch.serviceType == null || paramsPatch.serviceType === ""))
        paramsPatch.serviceType = kuwaiti.serviceType;
      if (
        kuwaiti.rentalType &&
        (paramsPatch.rentalType == null || paramsPatch.rentalType === "")
      ) {
        paramsPatch.rentalType = kuwaiti.rentalType;
      }

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

      // Top-demand is deprecated on the chat. Any hallucinated top_demand
      // intent is downgraded to search_property; the no-area clarify is
      // handled uniformly by the HARD GUARD further below, so no duplicate
      // prompt wall here.
      if (intent === TOP_DEMAND_INTENT) {
        intent = "search_property";
      }

      if (!paramsPatch.areaCode && parsed.detectedAreaCode) {
        paramsPatch.areaCode = parsed.detectedAreaCode;
        isCompleteFinal = true;
        clarifyingQuestionsFinal = [];
      }

      // Multi-area: when the customer named 2+ distinct areas in one breath
      // ("الخيران بنيدر جليعه"), the deterministic parser surfaces the full
      // list. We propagate it as `areaCodes` so the search service can run
      // a `whereIn` query — the customer's mental model is "show me from any
      // of these", not "pick one and search". The single `areaCode` stays
      // populated (first match) for backward-compat consumers that haven't
      // migrated to the array yet.
      if (
        Array.isArray(parsed.detectedAreaCodes) &&
        parsed.detectedAreaCodes.length >= 2 &&
        !Array.isArray(paramsPatch.areaCodes)
      ) {
        paramsPatch.areaCodes = parsed.detectedAreaCodes;
        isCompleteFinal = true;
        clarifyingQuestionsFinal = [];
      }

      // Chalet-belt expansion: when the customer wants a chalet but is
      // location-vague ("ابي شاليه شنو متوفر" / "أي منطقة عندك" / "كله") and
      // didn't name any specific area, expand to the canonical chalet belt
      // so they see real inventory across الخيران، بنيدر، الجليعة... instead
      // of getting bounced with "بأي منطقة؟". The intent here is curated
      // browsing, not a pinpoint search.
      // Tier 1 widening: Kuwaitis rarely phrase "show me everything" with the
      // textbook phrasings. They use throwaway browse cues like "بس وريني",
      // "ودّيني على شي", "انت شوف"، "أي شي" — all of which mean the same
      // "I haven't picked an area, surface inventory and let me browse".
      // Gating remains tight (`type === "chalet"` AND no area picked AND no
      // multi-area list), so widening doesn't trigger on unrelated chat.
      const chaletBeltVagueRegex =
        /(?:ا?ي\s*منطق[هة])|(?:كل\s*ال?مناطق)|(?:شنو\s*متوفر)|(?:عاد[يى]\s*ا?ب[يى]\s*ا?شوف)|(?:كل[هه])|(?:any\s*area)|(?:show\s*me\s*all)|(?:ا?ي\s*ش[يى])|(?:بس\s*وريني)|(?:ودّ?يني)|(?:يعجبني)|(?:انت\s*شوف)|(?:عطني\s*لقط[هة])|(?:عرضلي\s*الموجود)|(?:وريني\s*شاليهات)/i;
      const turnIsChaletVague =
        (typeof paramsPatch.type === "string" &&
          (paramsPatch.type as string).trim().toLowerCase() === "chalet" &&
          !paramsPatch.areaCode &&
          !Array.isArray(paramsPatch.areaCodes) &&
          chaletBeltVagueRegex.test(rawMessage));
      if (turnIsChaletVague) {
        paramsPatch.areaCodes = CHALET_BELT_AREAS.slice();
        isCompleteFinal = true;
        clarifyingQuestionsFinal = [];
      }

      // Date Intelligence Layer — OpenAI does not extract dates; our
      // deterministic parser does (intent_parser.extractDateRangeFromText).
      // Merge whenever the parser found a valid range for THIS turn.
      if (parsed.dateRange) {
        paramsPatch.startDate = parsed.dateRange.startDate;
        paramsPatch.endDate = parsed.dateRange.endDate;
        paramsPatch.nights = parsed.dateRange.nights;
      }

      const previousContext = getSearchContextFromFilters(currentFilters);
      if (!paramsPatch.areaCode && previousContext.areaCode) paramsPatch.areaCode = previousContext.areaCode;
      // Carry forward an active multi-area selection if this turn didn't
      // overwrite it (e.g., a refinement turn where the customer just changed
      // budget but is still browsing the same belt).
      if (
        !Array.isArray(paramsPatch.areaCodes) &&
        Array.isArray(previousContext.areaCodes) &&
        previousContext.areaCodes.length >= 2
      ) {
        paramsPatch.areaCodes = previousContext.areaCodes.slice();
      }
      if ((!paramsPatch.type || paramsPatch.type === "") && previousContext.propertyType)
        paramsPatch.type = previousContext.propertyType;
      if ((!paramsPatch.serviceType || paramsPatch.serviceType === "") && previousContext.serviceType)
        paramsPatch.serviceType = previousContext.serviceType;
      if (paramsPatch.budget == null && previousContext.budget != null) paramsPatch.budget = previousContext.budget;
      if (paramsPatch.bedrooms == null && previousContext.bedrooms != null)
        paramsPatch.bedrooms = previousContext.bedrooms;
      // Carry dates forward across turns (same treatment as budget/bedrooms).
      // Only when this turn did NOT supply a fresh range.
      if (
        paramsPatch.startDate == null &&
        paramsPatch.endDate == null &&
        previousContext.startDate != null &&
        previousContext.endDate != null
      ) {
        paramsPatch.startDate = previousContext.startDate;
        paramsPatch.endDate = previousContext.endDate;
        if (previousContext.nights != null) paramsPatch.nights = previousContext.nights;
      }

      // HARD GUARD (budget_down with no anchor). When the customer pushes
      // back with "أرخص" / "اقل" / "اوفر" but never gave us a number, the
      // downstream `applyModifierToContext` multiplies a NULL budget by 0.9
      // — a silent no-op. The query re-runs with identical filters and the
      // customer sees the same listings, which feels like the bot ignored
      // them. Refuse the modifier here, force a budget clarify, and let the
      // turn close at "what's your nightly budget?" instead of pretending we
      // refined anything. The empathy phrasing matches the persona prompt's
      // "بحدود كم ميزانيتك بالليلة" line so server + LLM agree on copy.
      if (
        parsed.modifier?.type === "budget_down" &&
        previousContext.budget == null &&
        !referencedPropertyId
      ) {
        parsed.modifier = null;
        isCompleteFinal = false;
        clarifyingQuestionsFinal = [
          "ولا يهمك، السوق هاللحين شاد حيله — بحدود كم ميزانيتك بالليلة عشان أصيد لك لقطة تناسبك؟",
        ];
      }

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

      // HARD GUARD (no-area fallback).
      //   The LLM occasionally sets is_complete=true on "ابي شاليه للايجار"
      //   even though the user hasn't told us WHERE. That triggers a no-area
      //   query, lands on zero results, and surfaces the "ما نزل شي" copy
      //   while the normal search page is full of chalets — which is the
      //   exact bug the product team flagged. We refuse to run a no-area
      //   search and instead ask one warm, type-aware clarifying question.
      //
      //   Short-circuit intents (greeting/booking_intent/hesitation) already
      //   returned above; reference_listing sets is_complete=true against a
      //   concrete propertyId, so it has its own data and is excluded here.
      const finalAreaCode =
        typeof finalParamsPatch.areaCode === "string"
          ? (finalParamsPatch.areaCode as string).trim()
          : "";
      if (
        !referencedPropertyId &&
        intent !== "greeting" &&
        intent !== "booking_intent" &&
        intent !== "hesitation" &&
        finalAreaCode === ""
      ) {
        isCompleteFinal = false;
        if (clarifyingQuestionsFinal.length === 0) {
          const inferredType =
            (typeof finalParamsPatch.type === "string" && (finalParamsPatch.type as string).trim()) ||
            (typeof paramsPatch.type === "string" && (paramsPatch.type as string).trim()) ||
            (kuwaiti.propertyType ? String(kuwaiti.propertyType) : "") ||
            "";
          clarifyingQuestionsFinal = [buildAreaClarifyQuestion(inferredType, locale)];
        }
      }

      // HARD GUARD (chalet rental cadence) — AUTHORITATIVE.
      //
      //   When the customer wants a chalet for rent in a known area but never
      //   said whether they want a daily (weekend / per-night) or a monthly
      //   (long-term) chalet, we MUST resolve the cadence before searching.
      //   The two segments live under different `rentalType` values in
      //   Firestore and price very differently ("KWD 95 / ليلة" vs
      //   "KWD X / شهر"), so guessing produces empty pages or off-budget
      //   options.
      //
      //   This guard runs in two stages:
      //
      //   (1) SMART INFERENCE — if the user already gave us a strong daily
      //       signal in the same turn (a parsed date range, an explicit
      //       `nights` count, or counted nights via the static parser), we
      //       stamp `rentalType=daily` and proceed straight to search. The
      //       customer never sees a redundant "daily or monthly?" question
      //       when they already implicitly answered it.
      //
      //   (2) FORCED CLARIFY — if cadence is still missing after inference,
      //       we OVERRIDE whatever clarifying question the LLM produced
      //       (e.g. "كم ليلة ناوي؟", which assumes daily) and replace it
      //       with the proper "تبيه يومي ولا شهري؟" question. The previous
      //       version gated this behind `length === 0`, which let the LLM's
      //       wrong question win and skip the cadence check entirely — that
      //       was the exact production bug customers reported.
      const finalType =
        typeof finalParamsPatch.type === "string"
          ? (finalParamsPatch.type as string).trim().toLowerCase()
          : "";
      let finalServiceType =
        typeof finalParamsPatch.serviceType === "string"
          ? (finalParamsPatch.serviceType as string).trim().toLowerCase()
          : "";
      let finalRentalType =
        typeof finalParamsPatch.rentalType === "string"
          ? (finalParamsPatch.rentalType as string).trim().toLowerCase()
          : "";

      // SMART DEFAULT (chalet → rent). Kuwaiti chalet inventory is
      // overwhelmingly rentals (daily weekend stays + monthly long-term).
      // Sale-only chalets are rare and worded explicitly when they exist
      // ("شاليه للبيع"). When the customer says "ابي شاليه" with no
      // rent/sale phrase, leaving `serviceType=""` causes the cadence
      // guard below to skip its `serviceType === "rent"` precondition,
      // which then routes the turn into a no-cadence search and lands on
      // mismatched results. Stamping rent here is product policy: we
      // serve the dominant intent, and an explicit "للبيع" still wins
      // because the LLM emits `serviceType=sale` in `paramsPatch` which
      // already merged into `finalParamsPatch` above this line.
      const finalServiceTypeIsBlank =
        finalServiceType === "" || finalServiceType == null;
      if (finalType === "chalet" && finalServiceTypeIsBlank) {
        finalParamsPatch.serviceType = "rent";
        finalServiceType = "rent";
      }

      // Stage (1): smart implicit-daily inference.
      const cadenceGuardApplies =
        !referencedPropertyId &&
        intent !== "greeting" &&
        intent !== "booking_intent" &&
        intent !== "hesitation" &&
        finalAreaCode !== "" &&
        finalType === "chalet" &&
        finalServiceType === "rent";

      if (cadenceGuardApplies && finalRentalType === "") {
        const hasParsedDateRange =
          typeof finalParamsPatch.startDate === "string" &&
          (finalParamsPatch.startDate as string).trim() !== "" &&
          typeof finalParamsPatch.endDate === "string" &&
          (finalParamsPatch.endDate as string).trim() !== "";
        const parsedNights =
          typeof finalParamsPatch.nights === "number"
            ? (finalParamsPatch.nights as number)
            : null;
        const hasNightsCount =
          parsedNights != null && Number.isFinite(parsedNights) && parsedNights > 0;
        if (hasParsedDateRange || hasNightsCount) {
          finalParamsPatch.rentalType = "daily";
          finalRentalType = "daily";
        }
      }

      // Stage (2): force the cadence question when still missing — this
      // OVERRIDES any LLM-produced clarifying question for this turn.
      if (cadenceGuardApplies && finalRentalType === "") {
        isCompleteFinal = false;
        clarifyingQuestionsFinal = [buildChaletCadenceClarifyQuestion(locale)];
      }

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
