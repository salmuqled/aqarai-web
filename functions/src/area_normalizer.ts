/**
 * Area Normalization: map common spelling variations of Kuwaiti area names
 * to the official name used in the database.
 */

const areaAliases: Record<string, string> = {
  // الزهراء
  "الزهره": "الزهراء",
  "الزهرة": "الزهراء",
  "الزهرا": "الزهراء",
  "الزهراء": "الزهراء",

  // الجابرية
  "الجابريه": "الجابرية",
  "الجابريه ": "الجابرية",
  "الجابرية": "الجابرية",

  // السالمية
  "السالميه": "السالمية",
  "السالمية": "السالمية",

  // الفنطاس
  "الفنطاس": "الفنطاس",

  // القادسية
  "القادسيه": "القادسية",
  "القادسية": "القادسية",

  // النزهة
  "النزهه": "النزهة",
  "النزهة": "النزهة",

  // الدسمة
  "الدسمه": "الدسمة",
  "الدسمة": "الدسمة",

  // الشامية
  "الشاميه": "الشامية",
  "الشامية": "الشامية",

  // الخالدية
  "الخالديه": "الخالدية",
  "الخالدية": "الخالدية",

  // كيفان
  "كيفان": "كيفان",

  // الفروانية
  "الفروانيه": "الفروانية",
  "الفروانية": "الفروانية",

  // حولي
  "حولي": "حولي",

  // الرميثية
  "الرميثيه": "الرميثية",
  "الرميثية": "الرميثية",

  // العديلية
  "العديليه": "العديلية",
  "العديلية": "العديلية",

  // اليرموك
  "اليرموك": "اليرموك",

  // المنصورية
  "المنصوريه": "المنصورية",
  "المنصورية": "المنصورية",
};

/**
 * Normalizes a single area name (e.g. user input or one token) to the official
 * name. Trims spaces, collapses extra spaces, then looks up in the alias map.
 */
export function normalizeAreaName(input: string): string {
  const normalized = input.trim().replace(/\s+/g, " ").toLowerCase();
  return areaAliases[normalized] ?? normalized;
}
