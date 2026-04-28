/**
 * Kuwait area names (Arabic) -> areaCode. Used by intent_parser for extractAreaFromText.
 * Matches lib/data/ar_to_en_mapping.dart + _code(en). Sorted by length in use.
 */
export const KUWAIT_AREAS: Record<string, string> = {
  "ضاحية حصه المبارك": "hessa_al_mubarak_district",
  "شمال غرب الصليبخات": "north_west_sulaibikhat",
  "الشويخ السكنية": "shuwaikh_residential",
  "الشويخ الصناعية": "shuwaikh_industrial",
  "القبلة - جبلة": "al_qibla_jibla",
  "عبدالله السالم": "abdullah_al_salem",
  "جابر الاحمد": "jaber_al_ahmad",
  "بنيد القار": "bneid_al_qar",
  "الصالحية": "al_sawlihya",
  "المباركية": "mubarakiya",
  "الدسمة": "dasma",
  "الدعية": "daeya",
  "الفيحاء": "faiha",
  "النزهة": "nuzha",
  "الروضة": "rawda",
  "العديلية": "adailiya",
  "الخالدية": "khaldiya",
  "كيفان": "kaifan",
  "الشامية": "shamiya",
  "اليرموك": "yarmouk",
  "المنصورية": "mansouriya",
  "القادسية": "qadisiya",
  "القيروان": "qairawan",
  "قرطبة": "qurtuba",
  "السرة": "surra",
  "الدوحة": "doha",
  "دسمان": "dasman",
  "غرناطة": "granada",
  "الصليبيخات": "sulaibikhat",
  "النهضة": "nahdha",
  "المرقاب": "al_murqab",
  "الشرق": "sharq",
  "غرب مشرف - مبارك العبدالله": "west_mishref_mubarak_al_abdullah",
  "جنوب السرة": "south_surra",
  "ميدان حولي": "maidan_hawalli",
  "الشعب السكني": "shaab_residential",
  "الشعب البحري": "shaab_marine",
  "حولي": "hawalli",
  "السالمية": "salmiya",
  "البدع": "bidaa",
  "الجابرية": "jabriya",
  "الرميثية": "rumaithiya",
  "مشرف": "mishref",
  "بيان": "bayan",
  "سلوى": "salwa",
  "الزهراء": "zahra",
  "السلام": "al_salam",
  "حطين": "hateen",
  "الشهداء": "shuhada",
  "الصديق": "al_siddiq",
  "العارضية الحرفية - الصناعية": "ardiya_industrial",
  "خيطان الجنوبي الجديدة": "south_new_khaitan",
  "عبدالله المبارك - غرب الجليب": "abdullah_al_mubarak",
  "جليب الشيوخ - الحساوي": "jleeb_al_shuyoukh_hassawi",
  "جنوب عبدالله المبارك": "south_abdullah_al_mubarak",
  "غرب عبدالله المبارك": "west_abdullah_al_mubarak",
  "اسطبلات الفروانية": "farwaniya_stables",
  "الفروانية": "farwaniya",
  "خيطان": "khaitan",
  "الرقعي": "riggae",
  "الضجيج": "dajeej",
  "الري": "rai",
  "الأندلس": "andalous",
  "العارضية": "ardiya",
  "العمرية": "omariya",
  "الرابية": "rabya",
  "الرحاب": "rehab",
  "صباح الناصر": "sabah_al_nasser",
  "اشبيلية": "ishbiliya",
  "الفردوس": "firdous",
  "صباح الاحمد البحرية - الخيران": "sabah_al_ahmad_marine_khiran",
  "علي صباح السالم - ام الهيمان": "ali_sabah_al_salem_umm_al_hayman",
  "صباح الأحمد السكنية": "sabah_al_ahmad_residential",
  "الخيران السكنية - الجانب البري": "khiran_residential_inland",
  // Product-decided primary alias: standalone "الخيران" (and the informal
  // no-ال variant "خيران") in chat refers to the coastal chalet-heavy area.
  // Exact-equals wins score 100 over "الخيران السكنية..." (startsWith 85)
  // in the resolver, guaranteeing the chalet marketplace slug for bare
  // "الخيران" / "خيران" / "في الخيران" queries.
  "الخيران": "sabah_al_ahmad_marine_khiran",
  "خيران": "sabah_al_ahmad_marine_khiran",
  "جنوب صباح الأحمد": "south_sabah_al_ahmad",
  "اسطبلات الاحمدي": "ahmadi_stables",
  "الوفرة السكنية": "wafra_housing",
  "مزارع الوفرة": "wafra_farms",
  "فهد الاحمد": "fahad_al_ahmad",
  "الشعيبة الصناعية": "shuaiba_industrial",
  "ميناء عبدالله": "mina_abdullah",
  "جابر العلي": "jaber_al_ali",
  "الاحمدي": "ahmadi",
  "المنقف": "mangaf",
  "الفحيحيل": "fahaheel",
  "أبو حليفة": "abu_halifa",
  "الظهر": "daher",
  "الرقة": "reqqa",
  "هدية": "hadiya",
  "الصباحية": "sabahiya",
  "الفنطاس": "fintas",
  "المهبولة": "mahboula",
  "العقيلة": "eqaila",
  "الضباعية": "dhubaiya",
  "الجليعة": "julaia",
  "الزور": "zour",
  "بنيدر": "bneider",
  "النويصيب": "nuwaiseeb",
  "جنوب سعد العبدالله": "south_saad_al_abdullah",
  "النسيم الجنوبي": "south_naseem",
  "امغرة الصناعية": "amghara_industrial",
  "اسطبلات الجهراء": "jahra_stables",
  "الجهراء الصناعية": "jahra_industrial",
  "سعد العبدالله": "saad_al_abdullah",
  "الجهراء": "jahra",
  "النعيم": "naeem",
  "القصر": "qasr",
  "الواحة": "waha",
  "تيماء": "taima",
  "الصليبية": "sulaibiya",
  "العيون": "oyoun",
  "الصبية": "subiya",
  "النسيم": "naseem",
  "كبد": "kabad",
  "المطلاع": "mutlaa",
  "الخويسات": "khusais",
  "الهجن": "hejin",
  "العبدلي": "abdali",
  "السالمي": "salmi",
  "النعايم": "naaim",
  "اسواق القرين - غرب ابوفطيرة الحرفية": "west_abu_fatira_craft_zone_aswaq_al_qurain",
  "مبارك الكبير": "mubarak_al_kabeer",
  "القرين": "qurain",
  "القصور": "qusour",
  "العدان": "adan",
  "المسيلة": "messila",
  "صباح السالم": "sabah_al_salem",
  "أبو فطيرة": "abu_fatira",
  "أبو الحصانية": "abu_hasaniya",
  "الفنيطيس": "funaitees",
  "المسايل": "maseila",
  "صبحان": "sabhan",

  // -------------------------------------------------------------------------
  // Common Arabic spelling / chat variants → same Firestore areaCode.
  // extractAreaFromText sorts by name length (longest first) so longer official
  // names (e.g. "الجهراء الصناعية") still win over short prefixes like "الجهرا".
  // -------------------------------------------------------------------------
  "الجهرا": "jahra",
  "جهراء": "jahra",
  "القادسيه": "qadisiya",
  "القادسيا": "qadisiya",
  "المهبوله": "mahboula",
  "الصباحيه": "sabahiya",
  "العقيله": "eqaila",
  "قرطبه": "qurtuba",
  "العارضيه": "ardiya",
};

// ---------------------------------------------------------------------------
// Chalet Belt — Kuwait's coastal chalet inventory.
//
// Customers typically think of "shaليه" as a single coastal product even though
// listings are filed under multiple distinct `areaCode` values along the
// southern coastline. This list is the canonical "what counts as a chalet
// area" set used by:
//
//   • The agent brain when the user is vague about location ("ابي شاليه شنو
//     متوفر") — we expand to the whole belt instead of forcing a single area.
//   • The multi-area parser when the user names two or more belt areas in one
//     message ("الخيران بنيدر جليعه") — we treat them as a list, never as a
//     concatenated slug.
//   • Smart suggestions when the customer's chosen area is empty — we offer
//     the next belt area as a chip instead of an unrelated neighbor.
//
// Every slug here MUST exist as a value in `KUWAIT_AREAS` above so listings
// stamped with these codes resolve correctly. Khiran's three sibling slugs
// are all included because customers searching "الخيران" expect to see
// inventory across the marine, inland, and bare-Khiran buckets.
export const CHALET_BELT_AREAS: readonly string[] = [
  "khiran",
  "sabah_al_ahmad_marine_khiran",
  "khiran_residential_inland",
  "bneider",
  "julaia",
  "dhubaiya",
  "zour",
  "nuwaiseeb",
  "mina_abdullah",
];

/**
 * `true` when [areaCode] is part of the chalet belt. Case-insensitive on the
 * input but the membership set is the canonical lowercase slugs above.
 */
export function isChaletBeltArea(areaCode: string | null | undefined): boolean {
  if (!areaCode) return false;
  const code = areaCode.trim().toLowerCase();
  return CHALET_BELT_AREAS.includes(code);
}

// ---------------------------------------------------------------------------
// AREA_INTELLIGENCE — Tier 1 broker knowledge layer.
//
// Each entry encodes the soft, tribal knowledge a Kuwaiti dallal carries in
// their head: the *vibe* of an area (premium / mid / budget tier), who it's
// for (family / youth / mixed), and a one-line warm description in اللهجة
// الكويتية البيضاء suitable for inlining into a reply.
//
// Why this lives here (not as a JSON file or Firestore doc):
//   • The data is small, slow-changing, and read on every chat turn.
//   • It must compile alongside `KUWAIT_AREAS` so a slug typo is a build
//     error, not a runtime miss.
//   • Both server (agent_brain) and rapid-prototype copy can import it
//     without round-tripping through Firestore.
//
// Coverage philosophy: this is a SEED for the chalet belt only. Areas
// without an entry fall back to generic copy in the orchestrator — never
// fabricate a vibe / tier for a slug that isn't listed here.
// ---------------------------------------------------------------------------

export type AreaTier = "premium" | "mid" | "budget";
export type AreaVibe = "family" | "youth" | "mixed";

export interface AreaProfile {
  /** Price-tier marker. Drives "بحدود كم ميزانيتك" anchors in copy. */
  tier: AreaTier;
  /** Who the area "fits" socially. Drives consultative follow-ups. */
  vibe: AreaVibe;
  /** One-line warm Kuwaiti description for inline use in replies. */
  description: string;
}

/**
 * Curated profiles for the highest-traffic Kuwait areas. Keys MUST match
 * canonical slugs in [KUWAIT_AREAS]. Add a slug here only when product has
 * signed off on the tier + vibe — guessing degrades the broker persona and
 * pollutes the Pivot logic in [findAlternativeArea].
 *
 * Coverage today (Tier 3.0):
 *   • Full chalet belt — every slug in [CHALET_BELT_AREAS] has a profile so
 *     [findAlternativeArea] always has a same-kind candidate when a chalet
 *     search returns zero rows.
 *   • Residential — top demand (premium + mid + investment), 13 slugs.
 *
 * Slugs not listed here return `null` from [getAreaProfile] and the
 * orchestrator falls back to generic copy.
 */
export const AREA_INTELLIGENCE: Record<string, AreaProfile> = {
  // -------------------------------- Chalet Belt -------------------------------
  bneider: {
    tier: "premium",
    vibe: "family",
    description: "راقية وهادية وحق عوايل.",
  },
  sabah_al_ahmad_marine_khiran: {
    tier: "mid",
    vibe: "youth",
    description: "قلب الحركة والوناسة والخدمات.",
  },
  khiran: {
    tier: "mid",
    vibe: "family",
    description: "ساحل الخيران بكل أجوائه — بحر، وناسة، وخدمات.",
  },
  julaia: {
    tier: "mid",
    vibe: "family",
    description: "البحر فيها نظيف وممتاز للسباحة.",
  },
  dhubaiya: {
    tier: "budget",
    vibe: "family",
    description: "هادية وبعيدة عن الزحمة، حق اللي يبي راحة.",
  },
  zour: {
    tier: "budget",
    vibe: "family",
    description: "البحر صافي وأجواء عائلية بعيد عن الضوضاء.",
  },
  nuwaiseeb: {
    tier: "budget",
    vibe: "mixed",
    description: "بعيد ومريح، مثالي للي يبي عزلة وهدوء.",
  },
  mina_abdullah: {
    tier: "budget",
    vibe: "mixed",
    description: "خيار اقتصادي وقريب من الديرة.",
  },

  // -------------------- Residential — Premium (تقليدية راقية) -----------------
  abdullah_al_salem: {
    tier: "premium",
    vibe: "family",
    description: "قمة الرقي والخصوصية، من أغلى وأهدى مناطق الكويت.",
  },
  shamiya: {
    tier: "premium",
    vibe: "family",
    description: "منطقة راقية، بيوتها واسعة وقريبة جداً من العاصمة.",
  },
  // NOTE: product spec spelled this "keifan"; canonical slug in KUWAIT_AREAS
  // is "kaifan". We use the canonical slug so listings filed under it
  // actually match — same content, correct key.
  kaifan: {
    tier: "premium",
    vibe: "family",
    description: "منطقة حيوية، تجمع بين الوجاهة والقرب من كل الخدمات.",
  },
  yarmouk: {
    tier: "premium",
    vibe: "family",
    description: "هادية، منظمة، وتعتبر من أكثر المناطق طلباً للسكن العائلي.",
  },
  qadisiya: {
    tier: "premium",
    vibe: "family",
    description: "من أعرق مناطق الكويت وقريبة من كل شي.",
  },
  rawda: {
    tier: "premium",
    vibe: "family",
    description: "راقية وبيوتها واسعة وحق عوايل كبار.",
  },
  salwa: {
    tier: "premium",
    vibe: "mixed",
    description: "قريبة من البحر وفيها حياة بين العوايل والشباب.",
  },

  // ------------------ Residential — Mid / High demand (سكن عوايل) -------------
  mishref: {
    tier: "mid",
    vibe: "family",
    description: "منطقة نموذجية، شوارعها واسعة وتمتاز بالهدوء والخدمات المتكاملة.",
  },
  jabriya: {
    tier: "mid",
    vibe: "mixed",
    description: "موقع استراتيجي، فيها تنوع كبير بين السكن الخاص والخدمات الطبية.",
  },
  sabah_al_salem: {
    tier: "mid",
    vibe: "mixed",
    description: "تطور عمراني سريع، وتنوع بين الفلل السكنية والشقق الاستثمارية الحديثة.",
  },
  surra: {
    tier: "mid",
    vibe: "family",
    description: "هادية وراقية وحق العوايل المستقرة.",
  },
  abdullah_al_mubarak: {
    tier: "mid",
    vibe: "family",
    description: "منطقة حديثة، بنيانها جديد وشرحة، ومثالية للعوائل الشابة.",
  },

  // ------------------- Residential — Investment / Rental (تجاري) --------------
  salmiya: {
    tier: "mid",
    vibe: "youth",
    description: "قلب الحركة التجارية والسياحية، كل شي تبيه حواليك ومثالية للنشاط.",
  },
  // NOTE: product spec spelled this "hawally"; canonical slug in KUWAIT_AREAS
  // is "hawalli". Canonical wins so real listings match.
  hawalli: {
    tier: "budget",
    vibe: "mixed",
    description: "منطقة استثمارية نشطة، تمتاز بأسعارها التنافسية وقربها من وسط البلد.",
  },
};

/**
 * Returns the [AreaProfile] for [areaCode] when curated, else `null`.
 * Case-insensitive on input; only canonical lowercase slugs match.
 */
export function getAreaProfile(
  areaCode: string | null | undefined
): AreaProfile | null {
  if (!areaCode) return null;
  const code = areaCode.trim().toLowerCase();
  return AREA_INTELLIGENCE[code] ?? null;
}

// ---------------------------------------------------------------------------
// PIVOT — alternative-area resolver.
//
// When a search returns zero results in the customer's requested area, the
// orchestrator pivots: instead of a dead-end "ما لقيت شي", we look up the
// requested area's profile and surface another area that matches the same
// social / price expectations. This is what a real dallal would do — they'd
// say "للأسف بنيدر فيه ضغط، بس روضة بنفس الجو الراقي".
//
// Algorithm (preference order):
//   1) EXACT — same tier AND same vibe (e.g. bneider → rawda: both premium+family)
//   2) SAME TIER — different vibe but same price expectation
//   3) SAME VIBE — different price tier but same audience
//   4) ANY same-kind — at least the same kind of area (chalet vs residential)
//
// Critical guardrail: alternatives are scoped to the SAME KIND of area. We
// never pivot a chalet request to a residential listing or vice versa
// (suggesting Qadisiya villas to someone asking for a Bneider chalet would
// look insane). [isChaletBeltArea] is the kind discriminator.
// ---------------------------------------------------------------------------

export interface AreaAlternative {
  /** Canonical lowercase slug of the suggested alternative. */
  slug: string;
  /** Curated profile for the alternative — never null when this object is returned. */
  profile: AreaProfile;
  /**
   * How the match was found. Useful for analytics and for tightening the
   * pivot copy ("بنفس الجو" vs "بميزانية مختلفة بس نفس النوع").
   */
  matchKind: "exact" | "same_tier" | "same_vibe" | "same_kind";
}

/**
 * Returns the best alternative area for [sourceSlug], or `null` when:
 *   • The source slug isn't curated in [AREA_INTELLIGENCE], OR
 *   • No same-kind alternative exists in [AREA_INTELLIGENCE].
 *
 * Same-kind constraint: if [sourceSlug] is in [CHALET_BELT_AREAS] only other
 * chalet-belt slugs are considered; otherwise only non-chalet-belt slugs.
 */
export function findAlternativeArea(
  sourceSlug: string | null | undefined
): AreaAlternative | null {
  if (!sourceSlug) return null;
  const code = sourceSlug.trim().toLowerCase();
  const source = AREA_INTELLIGENCE[code];
  if (!source) return null;

  const sourceIsChaletBelt = isChaletBeltArea(code);
  const candidates = Object.entries(AREA_INTELLIGENCE).filter(
    ([k]) => k !== code && isChaletBeltArea(k) === sourceIsChaletBelt
  );

  const exact = candidates.find(
    ([, p]) => p.tier === source.tier && p.vibe === source.vibe
  );
  if (exact) return { slug: exact[0], profile: exact[1], matchKind: "exact" };

  const sameTier = candidates.find(([, p]) => p.tier === source.tier);
  if (sameTier) {
    return { slug: sameTier[0], profile: sameTier[1], matchKind: "same_tier" };
  }

  const sameVibe = candidates.find(([, p]) => p.vibe === source.vibe);
  if (sameVibe) {
    return { slug: sameVibe[0], profile: sameVibe[1], matchKind: "same_vibe" };
  }

  if (candidates.length > 0) {
    const [slug, profile] = candidates[0];
    return { slug, profile, matchKind: "same_kind" };
  }
  return null;
}
