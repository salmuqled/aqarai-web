/**
 * Message understanding only. No Firestore, no reply composition, no UI.
 * Exposes parseUserMessage and supporting helpers.
 */
import { KUWAIT_AREAS } from "./kuwait_areas";
import { resolveAreaCodeFromMessage } from "./resolve_area_code_text";

// ---------------------------------------------------------------------------
// Arabic normalization
// ---------------------------------------------------------------------------

export function normalizeArabic(text: string): string {
  if (!text || typeof text !== "string") return "";
  return text
    .replace(/[\u0622\u0623\u0625]/g, "\u0627")
    .replace(/\u0629/g, "\u0647")
    .replace(/\u0649/g, "\u064A")
    .replace(/[\u064B-\u0652\u0670]/g, "");
}

// ---------------------------------------------------------------------------
// Kuwaiti intent (property/service/request type from phrases)
// ---------------------------------------------------------------------------

const SERVICE_PHRASES: { phrases: string[]; value: string }[] = [
  { phrases: ["بدلية", "بدليه", "بدل"], value: "exchange" },
  { phrases: ["للإيجار", "للايجار", "إيجار", "ايجار"], value: "rent" },
  { phrases: ["للبيع", "بيع"], value: "sale" },
];

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

const REQUEST_PHRASES: { phrases: string[]; value: string }[] = [
  { phrases: ["مطلوب"], value: "wanted" },
];

const FEATURE_PHRASES: { phrases: string[]; value: string }[] = [
  { phrases: ["زاوية", "زاويه"], value: "corner" },
  { phrases: ["بطن وظهر", "بطن و ظهر"], value: "double_street" },
];

const FLOORS_PHRASES: { phrases: string[]; value: number }[] = [
  { phrases: ["دورين"], value: 2 },
];

export interface KuwaitiIntentNormalized {
  propertyType?: string;
  serviceType?: string;
  requestType?: string;
  features?: string[];
  floors?: number;
  normalizedText: string;
}

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

// ---------------------------------------------------------------------------
// Area extraction
// ---------------------------------------------------------------------------

export function extractAreaFromText(text: string): string | null {
  if (!text || typeof text !== "string") return null;
  const normalized = normalizeArabic(text);
  const entries = Object.entries(KUWAIT_AREAS).sort((a, b) => b[0].length - a[0].length);
  for (const [areaAr, code] of entries) {
    const normalizedArea = normalizeArabic(areaAr);
    if (normalizedArea && normalized.includes(normalizedArea)) return code;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Modifier detection (أرخص شوي، أكبر، نفس المنطقة)
// ---------------------------------------------------------------------------

export function detectSearchModifier(text: string): { type: string } | null {
  if (!text || typeof text !== "string") return null;
  const t = normalizeArabic(text.trim());
  // Listing picks (الأرخص / الثاني …) handled by resolveTop3ResultReference — not budget refinement
  if (
    t.includes("الارخص") ||
    t.includes("الاغلى") ||
    t.includes("الاول") ||
    t.includes("الثاني") ||
    t.includes("الثالث") ||
    t.includes("الي قبل") ||
    t.includes("اللي قبل") ||
    t.includes("السابق")
  ) {
    return null;
  }
  if (t.includes("ارخص") || t.includes("اقل") || t.includes("اوفر")) return { type: "budget_down" };
  if (t.includes("اغلى") || t.includes("افخم")) return { type: "budget_up" };
  if (t.includes("اكبر") || t.includes("مساحه اكبر")) return { type: "size_up" };
  if (t.includes("اصغر")) return { type: "size_down" };
  if (t.includes("نفس المنطقه") || t.includes("نفس المنطقة")) return { type: "same_area" };
  return null;
}

// ---------------------------------------------------------------------------
// Buyer intent (residential vs investment)
// ---------------------------------------------------------------------------

export function detectBuyerIntent(text: string): "residential" | "investment" {
  const t = normalizeArabic(text);
  if (
    t.includes("استثمار") ||
    t.includes("دخل") ||
    t.includes("ايجار") ||
    t.includes("عائد")
  ) {
    return "investment";
  }
  return "residential";
}

// ---------------------------------------------------------------------------
// Booking-intent detection (high-intent: user wants to reserve right now)
// ---------------------------------------------------------------------------

/**
 * Detects a clear booking/reservation intent. Keep this deterministic and
 * narrow — we short-circuit the LLM path when it fires, so false positives
 * would steal the full search flow from the user.
 *
 * We require an explicit action verb/request form: "ابي احجز", "احجز لي",
 * "كيف احجز", "I want to book", "book it", "reserve", "how do I book".
 * Noun-only mentions ("الحجز" in a passive sentence) do NOT fire.
 */
export function detectBookingIntent(text: string): boolean {
  if (!text || typeof text !== "string") return false;
  const t = normalizeArabic(text);
  // Arabic patterns — anchored to a first-person or imperative form so that
  // "هالشاليه يقبل الحجز" never counts, but "ابي احجز" does.
  const arPatterns: RegExp[] = [
    /(?:^|\s)(?:ابي|ابغى|اريد|ودي)\s+(?:احجز|احجزه|احجزها|اسوي\s*حجز|اعمل\s*حجز)/,
    /(?:^|\s)(?:ممكن|اقدر)\s+احجز/,
    /(?:^|\s)احجز\s*(?:لي|ه|ها)?\b/,
    /(?:^|\s)كيف\s+احجز/,
    /(?:^|\s)ابي\s+اسوي\s+حجز/,
    /\bاحجزه\s*(?:لي|الحين|الحين\s*لو\s*سمحت)?\b/,
    /(?:^|\s)ارتب\s+لي\s+الحجز/,
  ];
  for (const re of arPatterns) {
    if (re.test(t)) return true;
  }
  const lower = text.toLowerCase();
  const enPatterns: RegExp[] = [
    /\b(?:i\s+(?:want|wanna|would\s+like)|can\s+i|how\s+do\s+i)\s+(?:to\s+)?(?:book|reserve)\b/,
    /\b(?:book|reserve)\s+(?:it|this|that)\b/,
    /\blet'?s\s+(?:book|reserve)\b/,
    /\bbook\s+(?:me|it)\s+(?:in|now)\b/,
  ];
  for (const re of enPatterns) {
    if (re.test(lower)) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Hesitation detection (user is undecided or asks for time)
// ---------------------------------------------------------------------------

/**
 * Detects hesitation / undecided phrasing. Used to trigger a calm,
 * reassuring reply ("خذ راحتك 👌 …") instead of pushing the user.
 *
 * Narrow on purpose — we don't want to swallow a legitimate "مو متأكد من
 * الميزانية" search turn. So we only fire when the hesitation stands alone
 * (no area, type, budget, or date is detected on the same turn).
 */
export function detectHesitationIntent(text: string): boolean {
  if (!text || typeof text !== "string") return false;
  const t = normalizeArabic(text);
  const arSignals: RegExp[] = [
    /(?:^|\s)محتار\b/,
    /(?:^|\s)مو\s*متاكد\b/,
    /(?:^|\s)مب\s*متاكد\b/,
    /(?:^|\s)لسه\s*مو\s*قرار\b/,
    /(?:^|\s)اخذ\s*وقتي\b/,
    /(?:^|\s)افكر\s*فيها\b/,
    /(?:^|\s)مترددة?\b/,
    /(?:^|\s)بفكر\s*(?:فيها|وارد\s*عليك)?\b/,
  ];
  const lower = text.toLowerCase();
  const enSignals: RegExp[] = [
    /\bnot\s+sure\b/,
    /\bi'?m\s+(?:undecided|hesitating|on\s+the\s+fence)\b/,
    /\blet\s+me\s+think\b/,
    /\bneed\s+(?:some\s+)?time\b/,
    /\bi'?ll\s+think\s+about\s+it\b/,
  ];
  const arHit = arSignals.some((re) => re.test(t));
  const enHit = enSignals.some((re) => re.test(lower));
  if (!arHit && !enHit) return false;
  // Suppress if the turn also carries real search signal — the user is
  // thinking out loud inside a live search, not asking for space.
  const kuwaiti = normalizeKuwaitiIntent(text);
  const hasArea = extractAreaFromText(text) != null;
  const hasType = kuwaiti.propertyType != null && String(kuwaiti.propertyType).trim() !== "";
  const hasService = kuwaiti.serviceType != null && String(kuwaiti.serviceType).trim() !== "";
  const hasBudget = /\d/.test(text) || /[٠-٩]/.test(text);
  if (hasArea || hasType || hasService || hasBudget) return false;
  return true;
}

// ---------------------------------------------------------------------------
// Feature / amenity question detection
// ---------------------------------------------------------------------------

/**
 * Feature keys mirror the boolean fields stored on each property document.
 * When the user asks a question like "فيه مسبح خارجي؟" / "is it beachfront?"
 * we short-circuit the LLM compose and answer directly from the listing's
 * `features` object (see `composeAgentReply`).
 */
export type AskedFeatureKey =
  | "hasPoolIndoor"
  | "hasPoolOutdoor"
  | "hasPoolAny"
  | "isBeachfront"
  | "hasGarden"
  | "hasElevator"
  | "hasCentralAC"
  | "hasSplitAC"
  | "hasMaidRoom"
  | "hasDriverRoom"
  | "hasLaundryRoom";

/**
 * Parse the user's message for amenity/feature questions. Returns a
 * deduplicated, ordered list of feature keys the user is asking about.
 *
 * Ambiguous pool mentions ("مسبح" / "pool" without indoor/outdoor qualifier)
 * resolve to `hasPoolAny` so the answer layer can report both variants.
 */
export function detectAskedFeatures(text: string): AskedFeatureKey[] {
  if (!text || typeof text !== "string") return [];
  const t = normalizeArabic(text);
  const lower = text.toLowerCase();
  const hits = new Set<AskedFeatureKey>();

  // Pools — order matters: qualified forms first, generic fallback only
  // when no qualified form fired.
  const poolIndoorAr = /مسبح\s*داخلي|مسابح\s*داخليه/;
  const poolOutdoorAr = /مسبح\s*خارجي|مسابح\s*خارجيه/;
  const poolIndoorEn = /\bindoor\s+pool\b/;
  const poolOutdoorEn = /\boutdoor\s+pool\b/;
  const poolGenericAr = /\bمسبح\b|\bمسابح\b|\bحمام\s*سباحه\b/;
  const poolGenericEn = /\bpool\b|\bswimming\s+pool\b/;
  const isIndoor = poolIndoorAr.test(t) || poolIndoorEn.test(lower);
  const isOutdoor = poolOutdoorAr.test(t) || poolOutdoorEn.test(lower);
  if (isIndoor) hits.add("hasPoolIndoor");
  if (isOutdoor) hits.add("hasPoolOutdoor");
  if (!isIndoor && !isOutdoor && (poolGenericAr.test(t) || poolGenericEn.test(lower))) {
    hits.add("hasPoolAny");
  }

  // Beachfront / directly on the sea.
  const beachAr = /علي\s*البحر\s*مباشر|علي\s*البحر\s*مباشره|مباشر\s*علي\s*البحر|بحر\s*مباشر|علي\s*البحر\b/;
  const beachEn =
    /\bbeachfront\b|\bon\s+the\s+(?:sea|beach)\b|\bdirectly\s+on\s+the\s+(?:sea|beach)\b|\bsea\s*front\b/;
  if (beachAr.test(t) || beachEn.test(lower)) hits.add("isBeachfront");

  // Garden.
  if (/\bحديقه\b|\bبحديقه\b/.test(t) || /\bgarden\b|\byard\b/.test(lower)) hits.add("hasGarden");

  // Elevator.
  if (/\bاصانصير\b|\bمصعد\b/.test(t) || /\belevator\b|\blift\b/.test(lower)) hits.add("hasElevator");

  // Central AC.
  if (/تكييف\s*مركزي|مركزي\b/.test(t) || /\bcentral\s+ac\b|\bcentral\s+air\b/.test(lower)) {
    hits.add("hasCentralAC");
  }

  // Split / unit AC.
  if (/تكييف\s*وحدات|سبلت\b/.test(t) || /\bsplit\s+ac\b|\bunit\s+ac\b/.test(lower)) {
    hits.add("hasSplitAC");
  }

  // Maid room.
  if (/غرفه\s*خادمه|خادمه\b/.test(t) || /\bmaid\s+room\b/.test(lower)) hits.add("hasMaidRoom");

  // Driver room.
  if (/غرفه\s*سائق|سائق\b/.test(t) || /\bdriver\s+room\b/.test(lower)) hits.add("hasDriverRoom");

  // Laundry room.
  if (/غرفه\s*غسيل|لاندري/.test(t) || /\blaundry\s+room\b/.test(lower)) hits.add("hasLaundryRoom");

  return Array.from(hits);
}

/**
 * True when the user appears to be asking a yes/no question about one
 * or more amenities on a shown listing. Requires both a feature mention
 * AND some question signal (question mark, interrogative particle, or a
 * "does it have" verb) to avoid eating a fresh search like "أبي شاليه فيه
 * مسبح" where the user is expressing a preference, not asking about an
 * already-visible listing.
 */
export function isFeatureQuestion(text: string, features: AskedFeatureKey[]): boolean {
  if (!text || features.length === 0) return false;
  const t = normalizeArabic(text);
  const lower = text.toLowerCase();
  if (/[?؟]/.test(text)) return true;
  const arQuestionSignals = [
    /(?:^|\s)هل\b/,
    /(?:^|\s)فيه\b/,
    /(?:^|\s)في\s+(?:مسبح|حديقه|اصانصير|مصعد|بحر)/,
    /(?:^|\s)يحتوي\b/,
    /(?:^|\s)عنده\b/,
    /(?:^|\s)معه\b/,
    /(?:^|\s)يطل\s+علي\b/,
    /(?:^|\s)يوجد\b/,
    /(?:^|\s)وش\s+في/,
    /(?:^|\s)شنو\s+في/,
  ];
  const enQuestionSignals = [
    /\bdoes\s+it\s+have\b/,
    /\bis\s+it\s+(?:beachfront|on\s+the\s+(?:sea|beach))\b/,
    /\bis\s+there\b/,
    /\bhas\s+(?:a\s+)?(?:pool|garden|elevator|lift)\b/,
    /\bwith\s+(?:a\s+)?(?:pool|garden|elevator|beach|sea)\b/,
  ];
  if (arQuestionSignals.some((re) => re.test(t))) return true;
  if (enQuestionSignals.some((re) => re.test(lower))) return true;
  return false;
}

// ---------------------------------------------------------------------------
// Greeting detection
// ---------------------------------------------------------------------------

const GREETING_WORDS = [
  "السلام",
  "السلام عليكم",
  "هلا",
  "هلا والله",
  "مرحبا",
  "صباح الخير",
  "مساء الخير",
];

const GREETING_REPLIES_AR = [
  "هلا والله 👋 تدور شاليه، شقة، ولا بيت؟",
  "حياك الله 👌 شنو اللي يناسبك: إيجار يومي، شهري، ولا تمليك؟",
  "ياهلا ومرحبا 🙌 قل لي نوع العقار والمنطقة وأشيك لك على المتاح.",
  "مرحبا فيك 👋 عطني فكرة عن اللي في بالك وأرتب لك أفضل الخيارات.",
];

const MORNING_GREETING_REPLIES_AR = [
  "صباح الخير 🌞 شنو اللي تدور عليه اليوم — شاليه، شقة، ولا بيت؟",
  "صباح النور 👋 قل لي نوع العقار والمنطقة وأبشرك بالمتاح.",
  "صباحك خير 🌞 تبي إيجار ولا تمليك؟ خلني أضيّق لك الخيارات.",
];

const EVENING_GREETING_REPLIES_AR = [
  "مساء الخير 🌙 شنو اللي يناسبك — شاليه بالويكند، شقة، ولا بيت؟",
  "مساء النور 👋 قل لي المنطقة ونوع العقار وخلني أشيك لك على المتاح.",
  "مساءك خير 🌙 تبي إيجار يومي، شهري، ولا تمليك؟",
];

export function smartGreeting(userText: string): string {
  const t = normalizeArabic(userText);
  if (t.includes("صباح")) {
    return MORNING_GREETING_REPLIES_AR[Math.floor(Math.random() * MORNING_GREETING_REPLIES_AR.length)];
  }
  if (t.includes("مساء")) {
    return EVENING_GREETING_REPLIES_AR[Math.floor(Math.random() * EVENING_GREETING_REPLIES_AR.length)];
  }
  return GREETING_REPLIES_AR[Math.floor(Math.random() * GREETING_REPLIES_AR.length)];
}

export function isGreetingOnly(text: string): boolean {
  if (!text || typeof text !== "string") return false;
  const normalized = normalizeArabic(text.trim());
  const hasGreeting = GREETING_WORDS.some((w) => normalized.includes(normalizeArabic(w)));
  if (!hasGreeting) return false;
  const hasArea = extractAreaFromText(text) != null;
  const kuwaiti = normalizeKuwaitiIntent(text);
  const hasPropertyType = kuwaiti.propertyType != null && String(kuwaiti.propertyType).trim() !== "";
  const hasServiceType = kuwaiti.serviceType != null && String(kuwaiti.serviceType).trim() !== "";
  const hasBudget = /\d/.test(text);
  const hasRealEstateIntent = hasArea || hasPropertyType || hasServiceType || hasBudget;
  return !hasRealEstateIntent;
}

// ---------------------------------------------------------------------------
// New search trigger
// ---------------------------------------------------------------------------

const NEW_SEARCH_TRIGGERS = ["أبي", "ابي", "دور لي", "أبحث عن", "ابحث عن"];

export function isNewSearchTrigger(text: string): boolean {
  const t = normalizeArabic((text || "").trim());
  return NEW_SEARCH_TRIGGERS.some(
    (trigger) => t.startsWith(normalizeArabic(trigger)) || t === normalizeArabic(trigger)
  );
}

// ---------------------------------------------------------------------------
// Last-shown results memory (assistant top 3) — ordinal / price picks
// ---------------------------------------------------------------------------

export interface Top3ResultMemoryRow {
  propertyId: string;
  price: number | null;
  rank: number;
  propertyType?: string;
  area?: string;
}

function rowPrice(n: unknown): number | null {
  if (n == null || n === "") return null;
  if (typeof n === "number" && !Number.isNaN(n)) return n;
  const x = Number(n);
  return Number.isNaN(x) ? null : x;
}

/** Map user shorthand to one of the last shown listings (by rank or price). */
export function resolveTop3ResultReference(
  rawMessage: string,
  rows: Top3ResultMemoryRow[],
  locale: string
): string | null {
  if (!rows.length) return null;
  const msg = (rawMessage || "").trim();
  if (!msg) return null;
  const t = normalizeArabic(msg.toLowerCase());
  const tl = msg.toLowerCase();

  const byRank = (r: number): Top3ResultMemoryRow | null => {
    const found = rows.find((x) => x.rank === r);
    if (found) return found;
    return r >= 1 && r <= rows.length ? rows[r - 1]! : null;
  };

  const withPrice = rows.filter((r) => r.price != null && !Number.isNaN(r.price!));
  if (withPrice.length > 0) {
    if (
      t.includes("الارخص") ||
      t.includes("اقل سعر") ||
      t.includes("اوفر") ||
      tl.includes("cheapest") ||
      tl.includes("lowest price")
    ) {
      const min = withPrice.reduce((a, b) => (a.price! <= b.price! ? a : b));
      return min.propertyId;
    }
    if (
      t.includes("الاغلى") ||
      t.includes("اعلى سعر") ||
      tl.includes("most expensive") ||
      tl.includes("priciest") ||
      tl.includes("highest price")
    ) {
      const max = withPrice.reduce((a, b) => (a.price! >= b.price! ? a : b));
      return max.propertyId;
    }
  }

  if (
    t.includes("الاول") ||
    t.includes("اول واحد") ||
    tl.includes("the first") ||
    tl === "first" ||
    tl.startsWith("first ")
  ) {
    return byRank(1)?.propertyId ?? rows[0]?.propertyId ?? null;
  }
  if (
    t.includes("الثاني") ||
    t.includes("ثاني واحد") ||
    tl.includes("the second") ||
    tl === "second" ||
    tl.startsWith("second ")
  ) {
    return byRank(2)?.propertyId ?? rows[1]?.propertyId ?? null;
  }
  if (t.includes("الثالث") || tl.includes("the third") || tl === "third") {
    return byRank(3)?.propertyId ?? rows[2]?.propertyId ?? null;
  }

  // Last card in the assistant list (bottom of the top 3)
  if (
    t.includes("الي قبل") ||
    t.includes("اللي قبل") ||
    t.includes("السابق") ||
    t.includes("ذاك") ||
    t.includes("الاخير") ||
    t.includes("اخر واحد") ||
    tl.includes("the previous") ||
    tl.includes("previous one") ||
    tl.includes("the last") ||
    tl.includes("last one")
  ) {
    const last = rows.reduce((a, b) => (a.rank >= b.rank ? a : b));
    return last.propertyId;
  }

  // English ordinals without "the"
  if (locale === "en") {
    if (/^1st\b|^#1\b/i.test(tl.trim())) return byRank(1)?.propertyId ?? rows[0]?.propertyId ?? null;
    if (/^2nd\b|^#2\b/i.test(tl.trim())) return byRank(2)?.propertyId ?? rows[1]?.propertyId ?? null;
    if (/^3rd\b|^#3\b/i.test(tl.trim())) return byRank(3)?.propertyId ?? rows[2]?.propertyId ?? null;
  }

  return null;
}

export function normalizeTop3MemoryRows(raw: unknown[]): Top3ResultMemoryRow[] {
  if (!Array.isArray(raw)) return [];
  const out: Top3ResultMemoryRow[] = [];
  for (let i = 0; i < raw.length && out.length < 3; i++) {
    const row = raw[i] as Record<string, unknown>;
    const idRaw = row.propertyId ?? row.id;
    const propertyId = idRaw != null ? String(idRaw).trim() : "";
    if (!propertyId) continue;
    const rankRaw = row.rank;
    const rank =
      typeof rankRaw === "number" && rankRaw >= 1 && rankRaw <= 3
        ? rankRaw
        : out.length + 1;
    out.push({
      propertyId,
      price: rowPrice(row.price),
      rank,
      propertyType: row.propertyType != null ? String(row.propertyType) : undefined,
      area: row.area != null ? String(row.area) : undefined,
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Date Intelligence Layer
// ---------------------------------------------------------------------------
//
// Extracts a stay date range (checkIn/checkOut) from free-form Arabic/English
// user messages. Produces a hotel-convention contract:
//   - startDate : inclusive check-in day, ISO-8601 UTC midnight.
//   - endDate   : **exclusive** check-out day, ISO-8601 UTC midnight.
//   - nights    : endDate - startDate, in whole days (1..90).
//
// Safety rules (enforced here, not downstream):
//   1. If only one date can be inferred -> return null (do NOT assume).
//   2. If end <= start (reverse or same-day) -> return null.
//   3. If nights > 90 -> return null (implausible; likely parse error).
//   4. Days outside 1..31 -> return null.
//   5. No locale fabrication of month: we only promote to a month once a valid
//      day number is found. If month/year are ambiguous we resolve against the
//      provided [referenceDate] (defaulting to "today" UTC) and roll forward
//      to the next valid occurrence when the inferred start would be in the
//      past.
//
// This function is intentionally deterministic and side-effect free so it can
// be called from `parseUserMessage` without altering any existing behavior when
// no date expression is present (returns null).
// ---------------------------------------------------------------------------

export interface ParsedDateRange {
  /** ISO-8601 UTC midnight for the check-in day (inclusive). */
  startDate: string;
  /** ISO-8601 UTC midnight for the check-out day (exclusive, hotel contract). */
  endDate: string;
  /** Whole nights between startDate and endDate. Guaranteed >= 1 and <= 90. */
  nights: number;
}

const DATE_RANGE_MAX_NIGHTS = 90;

/** Arabic-Indic digits -> Western digits. Harmless on already-Latin input. */
function normalizeDigits(text: string): string {
  if (!text) return "";
  return text.replace(/[\u0660-\u0669]/g, (d) =>
    String(d.charCodeAt(0) - 0x0660)
  );
}

function toUtcMidnight(year: number, monthIndex: number, day: number): Date {
  return new Date(Date.UTC(year, monthIndex, day, 0, 0, 0, 0));
}

function isValidDayNumber(n: number): boolean {
  return Number.isInteger(n) && n >= 1 && n <= 31;
}

function isValidMonthNumber(n: number): boolean {
  return Number.isInteger(n) && n >= 1 && n <= 12;
}

/**
 * Arabic + English month lexicon. Values are 1-based month numbers.
 * Covers both Levantine (نيسان) and Gulf/MSA (أبريل) variants.
 */
const MONTH_LEXICON: Record<string, number> = {
  // English (long + short)
  january: 1, jan: 1,
  february: 2, feb: 2,
  march: 3, mar: 3,
  april: 4, apr: 4,
  may: 5,
  june: 6, jun: 6,
  july: 7, jul: 7,
  august: 8, aug: 8,
  september: 9, sep: 9, sept: 9,
  october: 10, oct: 10,
  november: 11, nov: 11,
  december: 12, dec: 12,
  // Arabic MSA / Gulf (written forms — matched after `normalizeArabic`)
  "يناير": 1,
  "فبراير": 2,
  "مارس": 3,
  "ابريل": 4, "إبريل": 4, "أبريل": 4,
  "مايو": 5,
  "يونيو": 6, "يونية": 6,
  "يوليو": 7, "يولية": 7,
  "اغسطس": 8, "أغسطس": 8,
  "سبتمبر": 9,
  "اكتوبر": 10, "أكتوبر": 10,
  "نوفمبر": 11,
  "ديسمبر": 12,
  // Arabic Levantine
  "كانون الثاني": 1,
  "شباط": 2,
  "اذار": 3, "آذار": 3,
  "نيسان": 4,
  "ايار": 5, "أيار": 5,
  "حزيران": 6,
  "تموز": 7,
  "اب": 8, "آب": 8,
  "ايلول": 9, "أيلول": 9,
  "تشرين الاول": 10, "تشرين الأول": 10,
  "تشرين الثاني": 11,
  "كانون الاول": 12, "كانون الأول": 12,
};

/**
 * Longest-match month lookup over a pre-normalized lowercased string.
 *
 * A hit must be bounded by a NON-LETTER on both sides, otherwise short
 * Levantine month names collide catastrophically with common Arabic words:
 *   "اب" (August, Levantine) would otherwise match inside "شاليه", "ابي",
 *   "باب", etc. JavaScript's `\b` does not recognize Arabic letters, so we
 *   implement the boundary check ourselves against the Arabic + Latin ranges.
 */
function findMonthInText(normalizedText: string): number | null {
  const isLetter = (ch: string | undefined): boolean => {
    if (!ch) return false;
    const code = ch.charCodeAt(0);
    // Arabic block (U+0600-U+06FF) or basic Latin a-z.
    if (code >= 0x0600 && code <= 0x06ff) return true;
    if (code >= 0x0041 && code <= 0x005a) return true;
    if (code >= 0x0061 && code <= 0x007a) return true;
    return false;
  };
  const keys = Object.keys(MONTH_LEXICON).sort((a, b) => b.length - a.length);
  for (const key of keys) {
    const normKey = /[\u0600-\u06FF]/.test(key) ? normalizeArabic(key) : key;
    if (!normKey) continue;
    let from = 0;
    while (from <= normalizedText.length - normKey.length) {
      const idx = normalizedText.indexOf(normKey, from);
      if (idx < 0) break;
      const prev = idx > 0 ? normalizedText[idx - 1] : undefined;
      const next = normalizedText[idx + normKey.length];
      if (!isLetter(prev) && !isLetter(next)) {
        return MONTH_LEXICON[key] ?? null;
      }
      from = idx + 1;
    }
  }
  return null;
}

function buildRange(
  startYear: number,
  startMonthIndex: number,
  startDay: number,
  endYear: number,
  endMonthIndex: number,
  endDay: number
): ParsedDateRange | null {
  if (!isValidDayNumber(startDay) || !isValidDayNumber(endDay)) return null;
  const start = toUtcMidnight(startYear, startMonthIndex, startDay);
  const end = toUtcMidnight(endYear, endMonthIndex, endDay);
  // Guard against JS Date rollover (e.g. Feb 31 -> Mar 3).
  if (start.getUTCDate() !== startDay || end.getUTCDate() !== endDay) return null;
  const diffMs = end.getTime() - start.getTime();
  const nights = Math.round(diffMs / 86_400_000);
  if (nights < 1 || nights > DATE_RANGE_MAX_NIGHTS) return null;
  return {
    startDate: start.toISOString(),
    endDate: end.toISOString(),
    nights,
  };
}

/**
 * Promote a (day, month?, year?) pair to a concrete calendar date relative to
 * `ref`. If only day-of-month is provided, we use ref's month/year and roll
 * forward by one month when the inferred start is strictly before today.
 */
function resolveCalendarDay(
  day: number,
  month: number | null,
  year: number | null,
  ref: Date
): { year: number; monthIndex: number; day: number } | null {
  if (!isValidDayNumber(day)) return null;
  const refY = ref.getUTCFullYear();
  const refM = ref.getUTCMonth(); // 0-based
  const refD = ref.getUTCDate();

  let y = year ?? refY;
  let mIdx = month != null ? month - 1 : refM;
  if (month != null && !isValidMonthNumber(month)) return null;

  if (year == null && month == null) {
    // Only day of month -> use current month, roll forward if day already passed today.
    if (day < refD) {
      mIdx = refM + 1;
      if (mIdx > 11) {
        mIdx = 0;
        y = refY + 1;
      }
    }
  } else if (year == null) {
    // Month is known, year is not -> use current year, roll forward if the
    // (month, day) is strictly before today.
    const candidate = toUtcMidnight(refY, mIdx, day);
    const refUtcMidnight = toUtcMidnight(refY, refM, refD);
    if (candidate.getTime() < refUtcMidnight.getTime()) {
      y = refY + 1;
    }
  }
  const built = toUtcMidnight(y, mIdx, day);
  if (built.getUTCDate() !== day || built.getUTCMonth() !== mIdx) return null;
  return { year: y, monthIndex: mIdx, day };
}

/**
 * Master entry: attempt to extract a date range from a message.
 *
 * Supported patterns (not exhaustive; designed for Kuwaiti/MSA + English):
 *   1. Bare day-only range   : "27-29", "27 - 29", "من 27 الى 29", "from 27 to 29".
 *   2. Day+month range       : "27-29 ابريل", "27 to 29 april", "27/4 - 29/4".
 *   3. Full dd/mm range      : "27/04/2026 - 29/04/2026", "2026-04-27 to 2026-04-29".
 *
 * If no unambiguous range is found, returns null. Callers MUST NOT fabricate
 * dates from a single-day hit; the function only returns a range when both
 * endpoints are inferred.
 */
export function extractDateRangeFromText(
  rawText: string,
  referenceDate?: Date
): ParsedDateRange | null {
  const raw = (rawText || "").trim();
  if (!raw) return null;

  const refNow = referenceDate ?? new Date();
  const ref = toUtcMidnight(
    refNow.getUTCFullYear(),
    refNow.getUTCMonth(),
    refNow.getUTCDate()
  );

  const digitized = normalizeDigits(raw);
  const norm = normalizeArabic(digitized.toLowerCase());

  // NOTE on Arabic normalization: `normalizeArabic` folds the final alef maqsura
  // U+0649 ('ى') into ya U+064A ('ي'), so both "إلى" and "الى" become "الي" after
  // normalization. Our bare-day regex operates on `norm`, so it must match "الي".
  // The ISO and dd/mm regexes operate on `digitized` (pre-normalization), so they
  // must match both forms.

  // 3a) Full ISO range: "YYYY-MM-DD ... YYYY-MM-DD"
  const iso = digitized.match(
    /(\d{4})[-/](\d{1,2})[-/](\d{1,2})\s*(?:-|to|until|\u0625\u0644\u0649|\u0627\u0644\u0649|\u0627\u0644\u064A)\s*(\d{4})[-/](\d{1,2})[-/](\d{1,2})/i
  );
  if (iso) {
    const r = buildRange(
      Number(iso[1]), Number(iso[2]) - 1, Number(iso[3]),
      Number(iso[4]), Number(iso[5]) - 1, Number(iso[6])
    );
    if (r) return r;
  }

  // 3b) Day/month range with optional year: "27/04[/2026] - 29/04[/2026]"
  //     Accepts '-', 'to', Arabic 'إلى'/'الى'.
  const dmy = digitized.match(
    /(\d{1,2})[\/.](\d{1,2})(?:[\/.](\d{2,4}))?\s*(?:-|to|until|\u0625\u0644\u0649|\u0627\u0644\u0649|\u0627\u0644\u064A)\s*(\d{1,2})[\/.](\d{1,2})(?:[\/.](\d{2,4}))?/i
  );
  if (dmy) {
    const d1 = Number(dmy[1]);
    const m1 = Number(dmy[2]);
    const y1Raw = dmy[3] != null ? Number(dmy[3]) : null;
    const d2 = Number(dmy[4]);
    const m2 = Number(dmy[5]);
    const y2Raw = dmy[6] != null ? Number(dmy[6]) : null;
    const normYear = (y: number | null): number | null => {
      if (y == null) return null;
      if (y < 100) return 2000 + y; // '26 -> 2026
      return y;
    };
    const resolvedStart = resolveCalendarDay(d1, m1, normYear(y1Raw), ref);
    const endYearInput = y2Raw != null ? normYear(y2Raw) : resolvedStart?.year ?? null;
    const resolvedEnd = resolveCalendarDay(d2, m2, endYearInput, ref);
    if (resolvedStart && resolvedEnd) {
      const r = buildRange(
        resolvedStart.year, resolvedStart.monthIndex, resolvedStart.day,
        resolvedEnd.year, resolvedEnd.monthIndex, resolvedEnd.day
      );
      if (r) return r;
    }
  }

  // 2) Day-only range with trailing or leading month word:
  //    "27 - 29 april", "من 27 إلى 29 ابريل", "april 27-29".
  //
  // 1) Or bare day-only range without a month word ("27-29", "من 27 إلى 29",
  //    "from 27 to 29"). Month/year are inferred against [ref].
  // After `normalizeArabic`, both "إلى" and "الى" collapse to "الي"
  // (U+0627 U+0644 U+064A). We also keep the pre-normalization forms for
  // defense in depth (in case any caller feeds already-normalized text).
  const AR_ILA = "(?:\\u0627\\u0644\\u064A|\\u0627\\u0644\\u0649|\\u0625\\u0644\\u0649)";
  const dayRangeMatchers: RegExp[] = [
    // "من [تاريخ] 27 [إلى|الى] 29" — allow up to 15 non-digit chars between
    // the Arabic trigger word "من" and the first day number so phrases like
    // "من تاريخ 27 إلى 29" are handled. The Arabic word for "date" / spaces /
    // punctuation all slip through this window.
    new RegExp(
      "\\u0645\\u0646[^0-9]{0,15}?(\\d{1,2})\\s*(?:" + AR_ILA + "|-|\\u2013|\\u2014)\\s*(\\d{1,2})"
    ),
    // "from 27 to 29" / "between 27 and 29"
    /\b(?:from|between)\s+(\d{1,2})\s+(?:to|and|-|\u2013)\s+(\d{1,2})\b/i,
    // Bare Arabic day-to-day without "من" prefix: "27 الى 29".
    new RegExp(
      "(?:^|[^\\d])(\\d{1,2})\\s*" + AR_ILA + "\\s*(\\d{1,2})(?!\\d)"
    ),
    // Plain "27-29" / "27 - 29" / "27 to 29" (English keyword "to").
    /(?:^|[^\d])(\d{1,2})\s*(?:-|\u2013|\u2014|to|until)\s*(\d{1,2})(?!\d)/i,
  ];

  let dayStart: number | null = null;
  let dayEnd: number | null = null;
  for (const re of dayRangeMatchers) {
    const m = norm.match(re);
    if (m) {
      dayStart = Number(m[1]);
      dayEnd = Number(m[2]);
      if (isValidDayNumber(dayStart) && isValidDayNumber(dayEnd)) break;
      dayStart = null;
      dayEnd = null;
    }
  }

  if (dayStart == null || dayEnd == null) return null;

  const monthFromText = findMonthInText(norm);
  const yearMatch = digitized.match(/\b(20\d{2})\b/);
  const yearFromText = yearMatch ? Number(yearMatch[1]) : null;

  const rs = resolveCalendarDay(dayStart, monthFromText, yearFromText, ref);
  if (!rs) return null;
  // Carry month/year forward to the end day (bare "27-29" means same month).
  const re2 = resolveCalendarDay(
    dayEnd,
    monthFromText ?? rs.monthIndex + 1,
    yearFromText ?? rs.year,
    ref
  );
  if (!re2) return null;

  const built = buildRange(
    rs.year, rs.monthIndex, rs.day,
    re2.year, re2.monthIndex, re2.day
  );
  return built;
}

// ---------------------------------------------------------------------------
// Main entry: parse user message (no Firestore, no OpenAI)
// ---------------------------------------------------------------------------

export interface ParsedIntentResult {
  greeting?: boolean;
  greetingReply?: string;
  paramsPatch: Record<string, unknown>;
  modifier?: { type: string } | null;
  buyerIntent?: "residential" | "investment";
  isNewSearch?: boolean;
  detectedAreaCode?: string | null;
  /** For orchestrator: requestType, features, floors from Kuwaiti intent */
  requestType?: string;
  features?: string[];
  floors?: number;
  /** Extracted stay window (hotel-convention: endDate is exclusive). */
  dateRange?: ParsedDateRange | null;
}

export function parseUserMessage(rawMessage: string, _locale: string): ParsedIntentResult {
  const msg = (rawMessage || "").trim();
  if (!msg) {
    return { paramsPatch: {}, modifier: null };
  }

  if (isGreetingOnly(msg)) {
    return {
      greeting: true,
      greetingReply: smartGreeting(msg),
      paramsPatch: {},
      modifier: null,
    };
  }

  const kuwaiti = normalizeKuwaitiIntent(msg);
  // Full message first, then word n-grams; fall back to legacy Arabic substring map.
  const detectedAreaCode =
    resolveAreaCodeFromMessage(msg) ?? extractAreaFromText(msg);
  const modifier = detectSearchModifier(msg);
  const buyerIntent = detectBuyerIntent(msg);
  const isNewSearch = isNewSearchTrigger(msg);

  const paramsPatch: Record<string, unknown> = {};
  if (detectedAreaCode) paramsPatch.areaCode = detectedAreaCode;
  if (kuwaiti.propertyType) paramsPatch.type = kuwaiti.propertyType;
  if (kuwaiti.serviceType) paramsPatch.serviceType = kuwaiti.serviceType;

  const dateRange = extractDateRangeFromText(msg);
  if (dateRange) {
    paramsPatch.startDate = dateRange.startDate;
    paramsPatch.endDate = dateRange.endDate;
    paramsPatch.nights = dateRange.nights;
  }

  const result: ParsedIntentResult = {
    paramsPatch,
    modifier: modifier ?? null,
    buyerIntent,
    isNewSearch,
    detectedAreaCode: detectedAreaCode ?? null,
    dateRange: dateRange ?? null,
  };
  if (kuwaiti.requestType) result.requestType = kuwaiti.requestType;
  if (kuwaiti.features?.length) result.features = kuwaiti.features;
  if (kuwaiti.floors != null) result.floors = kuwaiti.floors;
  return result;
}
