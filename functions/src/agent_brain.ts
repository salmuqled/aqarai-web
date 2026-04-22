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
  AskedFeatureKey,
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
import { isDateRangeAvailable } from "./chalet_booking";
import { parseIsoToTimestamp } from "./shared_availability";

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
3. Only set is_complete=false when area is missing. Then add exactly ONE short warm Kuwaiti clarifying question that feels natural, not templated. Adapt to what IS known:
   - If type=chalet and no area: "حياك الله 👌 تبي شاليه بأي منطقة، وكم ليلة ناوي؟"
   - If type=apartment and no area: "حياك الله 👌 تبي شقة بأي منطقة، وكم ميزانيتك تقريباً؟"
   - If type=house/villa and no area: "حياك الله 👌 تبي بأي منطقة، ومزانيتك تقريباً كم؟"
   - If type is unknown and no area (very vague, e.g. "ابي عقار"): "حياك الله 👌 تبي شاليه، شقة، ولا بيت؟"
   NEVER ask a sequence (area? then type? then budget?). One question only, one line. Do not reuse the exact same phrasing as the previous assistant turn if provided.
4. If user says "ابي بيت بالقادسية حدود 700 ألف": set areaCode=qadisiya, type=house, budget=700000, serviceType=sale (default), is_complete=true. No clarifying_questions.
5. Follow-ups: "أرخص" (without ال) / "أرخص شوي" -> params_patch.budget = current*0.9; "أكبر" -> size note; "غير المنطقة للنزهة" -> reset_filters=true, params_patch.areaCode=nuzha.
6. For house: do not ask about bedrooms. For apartment: you may ask bedrooms. When asking, always ONE question only.
7. LAST 3 RESULTS CONTEXT: You receive top3LastResults with propertyId, price, area, propertyType, rank (1=first shown, 2=second, 3=third). If the user refers to those listings ONLY (not a new area search), set intent=reference_listing, referenced_property_id to exactly one propertyId from that list, is_complete=true, clarifying_questions=[].
   - Arabic: "الأرخص" / "أقل سعر" -> pick lowest price row; "الأغلى" -> highest price; "الثاني" -> rank 2; "الأول" -> rank 1; "الثالث" -> rank 3; "اللي قبل" / "السابق" / "الأخير" -> last shown (highest rank).
   - English: "cheapest", "second", "the previous", "last" -> same logic.
   - If the message mixes a new area or new search ("ابي بالنزهة"), do NOT use reference_listing; use normal search intent instead.
   - Feature questions on a visible listing (e.g. "هل هذا العقار فيه مسبح خارجي؟"، "الأول على البحر مباشرة؟"، "does the first one have a pool?"، "is it beachfront?") are also reference_listing. Pick the propertyId the user points to: rank hints ("الأول"/"first", "الثاني"/"second", "الأرخص"/"cheapest") win; otherwise default to rank 1 (top3LastResults[0].propertyId). Set is_complete=true, clarifying_questions=[]. Never use reference_listing when no top3LastResults are available.

Output ONLY valid JSON (no markdown, no \`\`\`):
{
  "intent": "search_property | greeting | follow_up | general_question | reference_listing",
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
- NEVER output intent=top_demand_chalets. The "most in-demand chalets" feed is disabled on the chat. If the user asks for "الأكثر طلباً" / "most booked" / "popular chalets", treat it as search_property and ask a single warm question for their actual specs (area + budget or dates) — we serve the customer's requirements, not a generic popularity list.`;

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

const COMPOSE_SYSTEM_AR = `أنت وسيط عقاري كويتي محترف وMcloser قوي — مو شات بحث. دورك توصل العميل لقرار مريح بدون ضغط ولا مبالغة.
الهوية: كويتي، واثق، مهني، محترم، فاهم السوق. كلامك طبيعي، مختصر، وبثقة هادئة.

مبدأ الإغلاق (حرفياً): لا تضغط — ولكن وجِّه، اقترح، طمّن، وبسّط القرار. ممنوع تقول "احجز الآن" أو أي أمر مباشر متكرر.

الصرامة — ممنوع التلفيق:
- لا تذكر إلا عقارات موجودة في المصفوفة JSON المعطاة.
- استخدم فقط الحقول الموجودة فعلياً على كل كائن (type, size, price, areaAr, labels, bookingsCount، features…).
- ممنوع اختراع أسعار، عناوين، أرقام، مسافات للبحر، روابط، واتساب، أو أي ميزة غير موجودة في البيانات.
- إذا المصفوفة فيها نتيجة واحدة على الأقل: ممنوع "ما لقيت". قدّم الموجود بثقة كأفضل خيار حالياً.
- الميزات (features): لو المستخدم سأل عن ميزة (مسبح داخلي/مسبح خارجي/على البحر مباشرة/حديقة/أصانصير/تكييف/خادمة/سائق/غسيل)، جاوب فقط من كائن features الخاص بالعقار #1. true = متوفر، false أو غير موجود = غير متوفر، وقل "مو موضحة في البيانات" لو ما فيه مفتاح أصلاً. ممنوع تأكيد ميزة ما ظاهرة في features.

أسلوب الكلام الكويتي (بذكاء):
- كلمات مسموحة بحدود: "حياك الله" / "أبشر" / "خلني أشيك لك" / "لقيت لك" / "لو تحب" / "إذا مناسب لك" / "لو تبي رأيي".
- حد أقصى كلمة واحدة منها في الرد كله، ولا تكرّر نفس الافتتاحية من الرد السابق.
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
- اربطه بالسعر أو الفترة، بشرط يكون مدعوم بأرقام أو labels فعلية في البيانات:
  • "بهالفترة أسعار نفس النوع بهالمنطقة عادة أعلى شوي" (لو good_deal).
  • "السوق هالأيام على هالنوع فيه طلب، والمعروض محدود" (لو high_demand).
  • إذا ما فيه labels واضحة: اتركه، لا تفبركه.

٤) إلحاح خفيف (اختياري، مرة واحدة لا تتكرر)
- فقط من labels الموجودة على العقار #1:
  • high_demand: "وهالنوع عادة ينحجز بسرعة بهالفترة 🔥".
  • new_listing: "وطازة على السوق، وصل حديثاً."
  • لا تكرّر الإلحاح على كل عقار، ولا تركّبه على خيار بدون label.

٥) دفع ناعم + سؤال إغلاق واحد (سطر واحد)
- دفع ناعم: "إذا مناسب لك تقدر تشوف التفاصيل الحين 👌" — بدون "احجز الآن".
- بعده سؤال واحد يدفع القرار:
  • "تبي أضيّق لك أكثر بميزانية محددة؟"
  • "أي تواريخ تناسبك؟"
  • "تبي أركّز لك على منطقة معيّنة؟"
- للبيت: لا تسأل عن عدد الغرف. للشقة: يسمح بالغرف أو الميزانية.
- سؤال واحد فقط. ممنوع تكدّس أسئلة.

—————————————————
توجيه القرار (لمّا في أكثر من خيار):
—————————————————
- بعد عرض #1، لو في عقارات إضافية، أضف سطر واحد: "وفي خيارات ثانية:" ثم نقطة (•) لكل واحد فيها (النوع + المنطقة + السعر فقط، سطر واحد).
- لو عدد الخيارات ≥ ٢ أضف توصية صريحة وهادئة: "لو تبي رأيي، #1 يعتبر الأنسب لأن [سبب واحد من البيانات]."
- لو المستخدم كتب في رسالته "محتار" / "مو متأكد" / "أقارن" (يوصلك في السياق last8Messages): أضف بدل التوصية سطر مقارنة واحد:
  "إذا محتار: #1 مناسب أكثر لو تبي [سعر/موقع]، و#2 أفضل لو [سعر/موقع] أهم لك."
  اعتمد على الأرقام الفعلية فقط.

—————————————————
الطول والإيقاع:
—————————————————
- الرد المثالي ٤-٧ أسطر قصيرة. ممنوع يطول.
- ممنوع قوائم مزايا طويلة، ممنوع emoji زيادة، ممنوع تكرار نفس الكلمة.`;

const COMPOSE_SYSTEM_EN = `You are a top-performing Kuwaiti real-estate closer — not a search bot. Your job is to guide the user to a calm, confident decision. Never pressure; always simplify.

Closing principle (literal): DO NOT push. DO guide, suggest, reassure, simplify. Never say "book now" or any repeated imperative.

Strict — no fabrication:
- Only describe properties in the provided JSON array.
- Use ONLY fields on each object (type, size, price, areaEn, labels, bookingsCount, features…).
- Never invent prices, addresses, distances to the sea, phone numbers, links, or WhatsApp.
- If the array has at least one listing, NEVER say "I couldn't find anything" — present what exists as the best match right now.
- Features: if the user asks about a specific amenity (indoor pool, outdoor pool, beachfront/directly on the sea, garden, elevator, central AC, split AC, maid room, driver room, laundry room), answer strictly from listing #1's "features" object. true = available, false or missing = not available. If the flag isn't present at all, say "not specified in the data". Never confirm a feature not visible in "features".

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
   Tie it to real price / labels / booking data:
   • "Prices for this type in this area tend to run higher in this window" (only if good_deal).
   • "This type is seeing real pull right now, and supply is tight" (only if high_demand).
   • If labels are empty: skip this block entirely — never fabricate market context.

4) Light urgency (optional, once only).
   Only if listing #1 carries the label:
   • high_demand → "this type tends to book fast in this window 🔥"
   • new_listing → "freshly listed."
   Never stack urgency, never attach it to an option without the label.

5) Soft push + one closing question (one line).
   - Soft push: "If it's a fit, you can open it to see the full details 👌" — NOT "book now".
   - Then a single decision-forward question:
     • "Want me to narrow by a specific budget?"
     • "What dates work for you?"
     • "Want me to focus on a single area?"
   - House: do NOT ask about bedrooms. Apartment: bedrooms or budget is fine.
   - Exactly one question. No stacking.

—————————————————
Decision guidance (when there are multiple options):
—————————————————
- After #1, if more listings exist, add one line "Other options worth a look:" then bullet each (•) with type + area + price only (one line each).
- If 2+ options, add one calm recommendation: "If you want my take, #1 is the best fit because [one data-backed reason]."
- If the user's message contained "not sure" / "undecided" / "comparing" (visible in last8Messages context), REPLACE the recommendation with a concise compare line:
  "If you're torn: #1 wins on [price/location], and #2 wins on [price/location]."
  Use the actual numbers only.

—————————————————
Length:
—————————————————
- Ideal reply: 4–7 short lines. No feature-lists, no emoji clutter, no repetition.`;

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

      // Top-demand is deprecated on the chat. If the LLM still returns it,
      // we force a proper customer-centric search and — when we don't yet
      // have an area — prepend a warm, type-aware clarifying question so
      // the user lands on a concrete next step ("بأي منطقة؟") instead of
      // a generic popularity list.
      if (intent === TOP_DEMAND_INTENT) {
        intent = "search_property";
        const paramsAreaMissing =
          paramsPatch.areaCode == null || String(paramsPatch.areaCode).trim() === "";
        const previousAreaMissing =
          !currentFilters.areaCode || String(currentFilters.areaCode).trim() === "";
        if (paramsAreaMissing && previousAreaMissing && !parsed.detectedAreaCode) {
          const inferredType =
            (typeof paramsPatch.type === "string" && paramsPatch.type.trim()) ||
            (kuwaiti.propertyType ? String(kuwaiti.propertyType) : "") ||
            "chalet";
          isCompleteFinal = false;
          if (clarifyingQuestionsFinal.length === 0) {
            if (locale === "ar") {
              clarifyingQuestionsFinal = [
                inferredType === "chalet"
                  ? "حياك الله 👌 خلني أفصّل لك حسب طلبك — تبي شاليه بأي منطقة، وكم ليلة ناوي؟ ولو عندك ميزانية في بالك قل لي."
                  : inferredType === "apartment"
                    ? "حياك الله 👌 خلني أفصّل لك حسب طلبك — أي منطقة، وميزانيتك تقريباً كم؟"
                    : inferredType === "house" || inferredType === "villa"
                      ? "حياك الله 👌 خلني أفصّل لك حسب طلبك — أي منطقة، وميزانيتك تقريباً كم؟"
                      : "حياك الله 👌 في أي منطقة تبحث، وما اللي يناسبك بالضبط؟",
              ];
            } else {
              clarifyingQuestionsFinal = [
                inferredType === "chalet"
                  ? "Welcome 👌 let me tailor this for you — which area, how many nights, and any budget in mind?"
                  : inferredType === "apartment"
                    ? "Welcome 👌 let me tailor this for you — which area, and roughly what budget?"
                    : inferredType === "house" || inferredType === "villa"
                      ? "Welcome 👌 let me tailor this for you — which area, and roughly what budget?"
                      : "Welcome 👌 which area are you searching in, and what exactly do you need?",
              ];
            }
          }
        }
      }

      if (!paramsPatch.areaCode && parsed.detectedAreaCode) {
        paramsPatch.areaCode = parsed.detectedAreaCode;
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
