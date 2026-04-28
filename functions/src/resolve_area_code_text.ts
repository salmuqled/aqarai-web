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

// Regex-safe escape for embedding an arbitrary user phrase inside a RegExp.
function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Whole-word / boundary-aware scoring.
 *   - `name` is the canonical area name (normalized).
 *   - `query` is the user input slice (normalized).
 * Raw substring `name.includes(query)` used to fire noisy false positives
 * (classic case: "ابي" hitting "الرابية" because the letters "ابي" appear
 *  mid-token). We now require the query to align on a word boundary — start
 * of string, whitespace, or dash — on BOTH ends of the match.
 */
function scoreNameMatch(name: string, query: string): number {
  if (!name || !query) return 0;
  if (name === query) return 100;
  if (query.length < 2) return 0;
  // startsWith with a trailing word boundary (or full-string match).
  const startsWithRe = new RegExp(`^${escapeRegex(query)}(?:$|[\\s\\-])`);
  if (startsWithRe.test(name)) return 85;
  // wholeWordContains: query surrounded by word boundaries inside the name.
  const containsRe = new RegExp(
    `(?:^|[\\s\\-])${escapeRegex(query)}(?:$|[\\s\\-])`
  );
  if (containsRe.test(name)) return 60;
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

/**
 * Strip multi-token Arabic greetings that COLLIDE with canonical area names
 * (i.e. the greeting contains a token that is itself a KUWAIT_AREAS key).
 *
 * Bug fixed: "السلام عليكم ابي شاليه بالخيران" → resolver used to pick up
 * "السلام" (an exact-token match for `al_salam`, score 100) from the greeting
 * phrase and short-circuit with the wrong area. Same pitfall exists with
 * "صباح الخير" colliding against `sabah_al_ahmad_residential`.
 *
 * We ONLY strip the multi-token greeting phrase — a bare "السلام" or "صباح"
 * typed on its own remains untouched and resolves normally.
 */
const ARABIC_GREETING_PATTERNS: RegExp[] = [
  // "[و?]السلام عليكم [ورحمة الله] [وبركاته]" and reversed order.
  /(?:^|\s)(?:و)?(?:ال)?سلام\s+عليكم(?:\s+ورحم[هة]\s+الل[هة])?(?:\s+وبركاته)?/gu,
  /(?:^|\s)(?:و)?عليكم\s+(?:ال)?سلام(?:\s+ورحم[هة]\s+الل[هة])?(?:\s+وبركاته)?/gu,
  // صباح / مساء + الخير / النور / الورد / الفل.
  /(?:^|\s)صباح\s+(?:الخير|النور|الورد|الفل)/gu,
  /(?:^|\s)مساء\s+(?:الخير|النور|الورد|الفل)/gu,
];

export function stripArabicGreetings(text: string): string {
  if (!text) return text;
  let t = text;
  for (const re of ARABIC_GREETING_PATTERNS) {
    t = t.replace(re, " ");
  }
  return collapseSpaces(t);
}

// Filler tokens dropped before n-gram scoring. Expanded to include the
// "I want" family ("ابي"، "ابغى"، "اريد"، "ودي"، "بدي"، "نبي") so a phrase
// like "ابي شاليه في الخيران" tokenizes down to ["شاليه", "الخيران"] and
// cannot substring-match "الرابية" / other areas via the word "ابي".
const AR_FILLER_NORMALIZED = new Set(
  [
    "في",
    "من",
    "إلى",
    "الي",
    "على",
    "الى",
    "ابي",
    "ابغى",
    "ابغي",
    "اريد",
    "ودي",
    "بدي",
    "نبي",
    "حاب",
    "حابب",
    "ابا",
    "ابه",
  ].map((w) => normalizeArabic(w)),
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
 * Tokens that syntactically mark "the next word is a location":
 *   في الخيران   / على البحر  / من السالمية  / منطقة حولي  / وين الشاليه
 * When we see one of these immediately before a token, that next token
 * (and a short window after it) is treated as the customer's TARGET area.
 */
const LOCATIVE_ANCHOR_TOKENS = new Set(
  ["في", "على", "من", "منطقة", "منطقه", "وين", "بمنطقة", "بمنطقه"].map(
    (w) => normalizeArabic(w),
  ),
);

/**
 * Target-area extractor — the principled "focus on what the customer ASKED
 * for" path. Returns the area explicitly anchored by Arabic locative
 * grammar, independent of whatever greetings / fillers surround it:
 *
 *   1. Any token with an attached ب+ال preposition ("بالخيران", "بالسالمية")
 *      — the "ب" is Arabic's shorthand "in/at" preposition, so whatever
 *      follows is by definition the location the customer is talking about.
 *
 *   2. Any token that IMMEDIATELY follows a locative anchor
 *      (في / على / من / منطقة / وين).
 *
 * This is agnostic to whether the customer greeted, used fillers, or typed
 * the area first/last. An area that appears *outside* these syntactic slots
 * (e.g. "السلام" inside "السلام عليكم") is intentionally ignored — the
 * customer was greeting, not pointing at Al Salam district.
 *
 * Returns null if no locative-anchored candidate resolves to a KUWAIT_AREAS
 * entry; the caller can then fall back to broader matching.
 */
function resolveLocativeAnchoredArea(raw: string): string | null {
  const pre = collapseSpaces(stripArabicGreetings(raw || ""));
  if (!pre) return null;
  const toks = tokenizeMessage(pre).map((t) => normalizeArabic(t));
  if (toks.length === 0) return null;

  // Up to 3-token forward window per anchor position — enough for
  // "الخيران السكنية - الجانب البري" style multi-word names.
  const WINDOW = 3;
  const candidates: string[] = [];
  const pushWindow = (start: string, i: number) => {
    candidates.push(start);
    let acc = start;
    for (let k = 1; k <= WINDOW && i + k < toks.length; k++) {
      acc += " " + toks[i + k];
      candidates.push(acc);
    }
  };

  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    // Signal A: ب+ال prefix — "بالخيران" → strip ب → "الخيران".
    // Safe because no KUWAIT_AREAS key starts with "بال..." (checked:
    // the only ب-initial areas are "بنيد القار", "بيان", "بنيدر").
    if (t.startsWith("بال") && t.length > 3) {
      pushWindow(t.substring(1), i);
    }
    // Signal B: token right after a locative anchor.
    if (i > 0 && LOCATIVE_ANCHOR_TOKENS.has(toks[i - 1])) {
      pushWindow(t, i);
    }
  }

  // Prefer the LONGEST successful match — it's the most specific canonical
  // area name (e.g. "الخيران السكنية - الجانب البري" beats plain "الخيران").
  let bestCode: string | null = null;
  let bestLen = 0;
  for (const c of candidates) {
    if (c.trim().length < 2) continue;
    const code = resolveAreaCodeFromText(c);
    if (code && c.length > bestLen) {
      bestCode = code;
      bestLen = c.length;
    }
  }
  return bestCode;
}

/**
 * Like [resolveAreaCodeFromText] but for full chat lines. Order of priority:
 *
 *   1. Locative-anchored target area — what the customer EXPLICITLY asked
 *      for (via "في X" / "بX" / "منطقة X"). Greetings and fillers have no
 *      effect here because they never carry these anchors.
 *
 *   2. Fallback — greeting-stripped full-string match, then n-gram scoring.
 *      Handles bare mentions like "الخيران" / "السالمية" typed alone.
 */
export function resolveAreaCodeFromMessage(raw: string): string | null {
  // Priority 1: what is the customer asking about?
  const anchored = resolveLocativeAnchoredArea(raw);
  if (anchored) return anchored;

  // Priority 2: greeting-stripped broad match (bare area mentions).
  const msg = collapseSpaces(stripArabicGreetings(raw || ""));
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
