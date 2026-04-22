/**
 * Market/area/buyer insight text only. May call Firestore for market stats. No full reply assembly.
 */
import type { SearchContext } from "./search_context";
import type { Firestore } from "firebase-admin/firestore";
import { detectBuyerIntent } from "./intent_parser";
import { computeAveragePrice, detectBestDeal } from "./ranking_engine";
import { isNormalListingMarketplaceVisible } from "./propertyVisibility";

export interface InsightBundle {
  priceRangeText?: string;
  marketText?: string;
  bestDealText?: string;
  buyerIntentText?: string;
  areaSuggestionText?: string;
}

// ---------------------------------------------------------------------------
// Price range
// ---------------------------------------------------------------------------

function computeAreaPriceRange(properties: Record<string, unknown>[]): { min: number; max: number } | null {
  if (!properties || properties.length === 0) return null;
  const prices = properties
    .map((p) => (typeof p.price === "number" ? p.price : Number(p.price)))
    .filter((p) => typeof p === "number" && !Number.isNaN(p));
  if (prices.length === 0) return null;
  return { min: Math.min(...prices), max: Math.max(...prices) };
}

function buildPriceRangeInsight(
  areaLabel: string,
  range: { min: number; max: number } | null,
  locale: string
): string {
  if (!range) return "";
  if (range.min === range.max) return "";
  if (locale === "ar") {
    return `للمرجع: متوسط الأسعار في ${areaLabel} حالياً بين ${range.min.toLocaleString("ar")} و${range.max.toLocaleString("ar")} دينار.`;
  }
  return `For reference: prices in ${areaLabel} are running between ${range.min.toLocaleString()} and ${range.max.toLocaleString()} KWD.`;
}

// ---------------------------------------------------------------------------
// Market demand/supply (Firestore)
// ---------------------------------------------------------------------------

async function getMarketDemandStats(
  db: Firestore,
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

async function getMarketSupplyStats(
  db: Firestore,
  areaCode: string,
  propertyType: string
): Promise<{ supplyCount: number }> {
  if (!areaCode?.trim() || !propertyType?.trim()) return { supplyCount: 0 };
  const q = db
    .collection("properties")
    .where("approved", "==", true)
    .where("isActive", "==", true)
    .where("listingCategory", "==", "normal")
    .where("hiddenFromPublic", "==", false)
    .where("type", "==", propertyType.trim())
    .where("areaCode", "==", areaCode.trim());
  const snap = await q.get();
  const supplyCount = snap.docs.filter((d) =>
    isNormalListingMarketplaceVisible(d.data())
  ).length;
  return { supplyCount };
}

type MarketSignal = "high_demand_low_supply" | "high_demand" | "low_demand" | "normal";

function analyzeMarket(demand: number, supply: number): MarketSignal {
  if (demand >= 10 && supply <= 3) return "high_demand_low_supply";
  if (demand >= 10 && supply > 10) return "high_demand";
  if (demand <= 3 && supply >= 10) return "low_demand";
  return "normal";
}

/** For ranking_engine / orchestrator: get market signal string for an area+type. */
export async function getMarketSignal(
  db: Firestore,
  areaCode: string,
  propertyType: string
): Promise<string> {
  try {
    const [demandRes, supplyRes] = await Promise.all([
      getMarketDemandStats(db, areaCode, propertyType),
      getMarketSupplyStats(db, areaCode, propertyType),
    ]);
    return analyzeMarket(demandRes.demandLast7Days, supplyRes.supplyCount);
  } catch {
    return "normal";
  }
}

const MARKET_INSIGHT_AR: Record<MarketSignal, string> = {
  high_demand_low_supply:
    "بهالفترة الطلب على هالنوع في {area} مرتفع والمعروض محدود — والأسعار عادة تمشي أعلى شوي.",
  high_demand: "بهالفترة فيه طلب ملحوظ على هالنوع في {area}.",
  low_demand: "الطلب حالياً هادئ على هالنوع في {area} — يعني فرصة تفاوض أوسع.",
  normal: "",
};

const MARKET_INSIGHT_EN: Record<MarketSignal, string> = {
  high_demand_low_supply:
    "Demand for this type in {area} is high right now and supply is tight — prices usually run a bit higher in this window.",
  high_demand: "There's real pull on this type in {area} at the moment.",
  low_demand: "Demand on this type in {area} is quieter right now — room to negotiate.",
  normal: "",
};

function getMarketInsightText(signal: MarketSignal, areaLabel: string, locale: "ar" | "en"): string {
  if (signal === "normal") return "";
  const template = locale === "ar" ? MARKET_INSIGHT_AR[signal] : MARKET_INSIGHT_EN[signal];
  return template.replace("{area}", areaLabel || (locale === "ar" ? "هذه المنطقة" : "this area"));
}

// ---------------------------------------------------------------------------
// Best deal
// ---------------------------------------------------------------------------

function buildBestDealInsightText(
  areaLabel: string,
  deal: Record<string, unknown> | null,
  averagePrice: number | null,
  locale: string
): string {
  if (!deal || averagePrice == null) return "";
  const price = typeof deal.price === "number" ? deal.price : Number(deal.price);
  if (typeof price !== "number" || Number.isNaN(price)) return "";
  const diff = Math.round(averagePrice - price);
  if (diff <= 0) return "";
  if (locale === "ar") {
    return `إشارة مفيدة: سعره أقل من متوسط ${areaLabel} بحوالي ${diff.toLocaleString("ar")} دينار — يعتبر سعر مُريح.`;
  }
  return `Useful signal: priced about ${diff.toLocaleString()} KWD below the average in ${areaLabel} — solid value.`;
}

// ---------------------------------------------------------------------------
// Buyer intent
// ---------------------------------------------------------------------------

function buildBuyerInsightText(areaLabel: string, intent: string, locale: string): string {
  if (intent !== "investment") return "";
  if (locale === "ar") {
    return `بالمناسبة، كثير من المستثمرين يبحثون عن عقارات في ${areaLabel} بسبب العائد الإيجاري الجيد.`;
  }
  return `Many investors look for properties in ${areaLabel} due to strong rental returns.`;
}

// ---------------------------------------------------------------------------
// Area intelligence (nearby areas suggestion)
// ---------------------------------------------------------------------------

const AREA_INTELLIGENCE: Record<string, string[]> = {
  nuzha: ["kaifan", "rawda"],
  qadisiya: ["kaifan", "khaldiya"],
  rumaithiya: ["salmiya", "jabriya"],
  jabriya: ["hawalli", "salmiya"],
  salmiya: ["hawalli"],
};

const AREA_CODE_TO_LABEL_AR: Record<string, string> = {
  kaifan: "كيفان",
  rawda: "الروضة",
  khaldiya: "الخالدية",
  salmiya: "السالمية",
  jabriya: "الجابرية",
  hawalli: "حولي",
};

const AREA_CODE_TO_LABEL_EN: Record<string, string> = {
  kaifan: "Kaifan",
  rawda: "Rawda",
  khaldiya: "Khaldiya",
  salmiya: "Salmiya",
  jabriya: "Jabriya",
  hawalli: "Hawalli",
};

function buildAreaSuggestionText(areaCode: string, locale: string): string {
  const nearby = AREA_INTELLIGENCE[areaCode];
  if (!nearby || nearby.length === 0) return "";
  const labelMap = locale === "ar" ? AREA_CODE_TO_LABEL_AR : AREA_CODE_TO_LABEL_EN;
  const labels = nearby.map((c) => labelMap[c] || c);
  if (locale === "ar") {
    return `ملاحظة: لو توسعنا شوي في المناطق، ممكن تلاقي خيارات أرخص في ${labels.join(" أو ")}.`;
  }
  return `Note: expanding your search slightly may find cheaper options in ${labels.join(" or ")}.`;
}

// ---------------------------------------------------------------------------
// Main: build all insight fragments
// ---------------------------------------------------------------------------

export async function buildInsights(params: {
  context: SearchContext;
  areaLabel: string;
  topResults: Record<string, unknown>[];
  rawMessage?: string;
  locale: string;
  db?: Firestore;
}): Promise<InsightBundle> {
  const { context, areaLabel, topResults, rawMessage, locale, db } = params;
  const bundle: InsightBundle = {};

  const priceRange = computeAreaPriceRange(topResults);
  bundle.priceRangeText = buildPriceRangeInsight(areaLabel, priceRange, locale);

  const avgPrice = computeAveragePrice(topResults);
  const bestDeal = avgPrice != null ? detectBestDeal(topResults, avgPrice) : null;
  bundle.bestDealText = buildBestDealInsightText(areaLabel, bestDeal, avgPrice, locale);

  const intent = context.intent ?? (rawMessage ? detectBuyerIntent(rawMessage) : "residential");
  bundle.buyerIntentText = buildBuyerInsightText(areaLabel, intent, locale);

  if (context.areaCode) {
    bundle.areaSuggestionText = buildAreaSuggestionText(context.areaCode, locale);
  }

  if (db && context.areaCode && context.propertyType) {
    try {
      const [demandRes, supplyRes] = await Promise.all([
        getMarketDemandStats(db, context.areaCode, context.propertyType),
        getMarketSupplyStats(db, context.areaCode, context.propertyType),
      ]);
      const signal = analyzeMarket(demandRes.demandLast7Days, supplyRes.supplyCount);
      bundle.marketText = getMarketInsightText(signal, areaLabel, locale as "ar" | "en");
    } catch {
      // non-fatal
    }
  }

  return bundle;
}
