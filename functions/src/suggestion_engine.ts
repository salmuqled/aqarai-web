/**
 * Quick suggestion chips (up to 3). No Firestore. Context-aware.
 */
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

const REFINEMENT_SUGGESTIONS_AR = [
  "أرخص شوي",
  "أكبر شوي",
  "نفس النوع في مناطق قريبة",
];

const REFINEMENT_SUGGESTIONS_EN = [
  "A bit cheaper",
  "A bit bigger",
  "Same type in nearby areas",
];

export function buildSmartSuggestions(params: {
  area?: string;
  propertyType?: string;
  serviceType?: string;
  locale: string;
  stage?: string;
  resultsCount?: number;
}): string[] {
  const { locale, stage, resultsCount = 0 } = params;
  const isAr = locale === "ar";

  if (stage === "refinement") {
    const refinement = isAr ? REFINEMENT_SUGGESTIONS_AR : REFINEMENT_SUGGESTIONS_EN;
    return refinement.slice(0, 3);
  }

  if (resultsCount > 0) {
    const base = isAr ? SUGGESTIONS_HAVE_RESULTS_AR : SUGGESTIONS_HAVE_RESULTS_EN;
    return base.slice(0, 3);
  }

  const noResults = isAr ? SUGGESTIONS_NO_RESULTS_AR : SUGGESTIONS_NO_RESULTS_EN;
  return noResults.slice(0, 3);
}
