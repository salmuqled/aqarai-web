/**
 * Free-text → Firestore areaCode (scoring: exact 100, prefix 85, contains 60).
 * Arabic + English labels from KUWAIT_AREAS + areaArToEn. Matches app kuwait_areas logic.
 */
import { areaArToEn } from "./invoice/invoicePdfAreaEn";
import { KUWAIT_AREAS } from "./kuwait_areas";

function normalizeArabic(text: string): string {
  if (!text || typeof text !== "string") return "";
  return text
    .replace(/[\u0622\u0623\u0625]/g, "\u0627")
    .replace(/\u0629/g, "\u0647")
    .replace(/\u0649/g, "\u064A")
    .replace(/[\u064B-\u0652\u0670]/g, "");
}

function collapseSpaces(s: string): string {
  return s.trim().replace(/\s+/g, " ");
}

function normalizeLatin(s: string): string {
  return collapseSpaces(s).toLowerCase();
}

function scoreNameMatch(name: string, query: string): number {
  if (!name || !query) return 0;
  if (name === query) return 100;
  if (name.startsWith(query)) return 85;
  if (name.includes(query)) return 60;
  return 0;
}

type AreaRow = { code: string; nameAr: string; nameEn: string };

const KUWAIT_AREA_ROWS: AreaRow[] = Object.entries(KUWAIT_AREAS).map(([nameAr, code]) => ({
  code,
  nameAr,
  nameEn: areaArToEn[nameAr] ?? "",
}));

export function resolveAreaCodeFromText(input: string): string | null {
  const collapsed = collapseSpaces(input);
  if (!collapsed) return null;
  const arQuery = normalizeArabic(collapsed);
  const latin = collapsed.toLowerCase();

  let bestScore = 0;
  let bestCode: string | null = null;

  for (const row of KUWAIT_AREA_ROWS) {
    const ar = collapseSpaces(row.nameAr);
    const arN = normalizeArabic(ar);
    const scoreAr = scoreNameMatch(arN, arQuery);

    const en = normalizeLatin(row.nameEn);
    const scoreEn =
      row.nameEn.trim().length > 0 ? scoreNameMatch(en, latin) : 0;

    const score = Math.max(scoreAr, scoreEn);
    if (score > bestScore) {
      bestScore = score;
      bestCode = row.code;
    }
  }

  return bestScore > 0 ? bestCode : null;
}

const TOKEN_SPLIT = /[\s\u060C.,;:!?،٫٬|/\\]+/u;

function tokenizeMessage(msg: string): string[] {
  return collapseSpaces(msg)
    .split(TOKEN_SPLIT)
    .map((t) => t.trim())
    .filter((t) => t.length > 0);
}

const AR_FILLER_NORMALIZED = new Set(
  ["في", "من", "إلى", "الي", "على", "الى"].map((w) => normalizeArabic(w)),
);

function filterWeakTokens(words: string[]): string[] {
  return words.filter((w) => {
    // Block very short Latin-only tokens; allow short Arabic (e.g. "شرق").
    if (w.length < 3 && !/[\u0600-\u06FF]/.test(w)) return false;
    const key = normalizeArabic(w);
    if (AR_FILLER_NORMALIZED.has(key)) return false;
    return true;
  });
}

/**
 * Like [resolveAreaCodeFromText] but for long chat lines: try the full string
 * first, then consecutive word n-grams (longest first, left-to-right). First
 * non-null code wins.
 */
export function resolveAreaCodeFromMessage(raw: string): string | null {
  const msg = collapseSpaces(raw);
  if (!msg) return null;

  const full = resolveAreaCodeFromText(msg);
  if (full) return full;

  const words = filterWeakTokens(tokenizeMessage(msg));
  if (words.length === 0) return null;

  const maxN = Math.min(6, words.length);
  for (let n = maxN; n >= 1; n--) {
    for (let i = 0; i + n <= words.length; i++) {
      const phrase = words.slice(i, i + n).join(" ");
      if (phrase.trim().length < 3) continue;
      const code = resolveAreaCodeFromText(phrase);
      if (code) return code;
    }
  }

  return null;
}
