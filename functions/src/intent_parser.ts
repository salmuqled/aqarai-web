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
  "وعليكم السلام.",
  "وعليكم السلام، حياك الله.",
  "هلا والله.",
  "ياهلا ومرحبا.",
  "مرحبا فيك.",
  "حياك الله.",
  "هلا فيك.",
  "ياهلا.",
];

const MORNING_GREETING_REPLIES_AR = [
  "صباح الخير.",
  "صباح النور.",
  "صباحك خير.",
  "صباح الخير، حياك الله.",
];

const EVENING_GREETING_REPLIES_AR = [
  "مساء الخير.",
  "مساء النور.",
  "مساء الخير، حياك الله.",
  "مساءك خير.",
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

  const result: ParsedIntentResult = {
    paramsPatch,
    modifier: modifier ?? null,
    buyerIntent,
    isNewSearch,
    detectedAreaCode: detectedAreaCode ?? null,
  };
  if (kuwaiti.requestType) result.requestType = kuwaiti.requestType;
  if (kuwaiti.features?.length) result.features = kuwaiti.features;
  if (kuwaiti.floors != null) result.floors = kuwaiti.floors;
  return result;
}
