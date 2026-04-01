/**
 * Shapes + reorders Arabic for environments (PDFKit) without native RTL.
 */
// arabic-reshaper ships without TypeScript types
// eslint-disable-next-line @typescript-eslint/no-require-imports
const ArabicReshaper = require("arabic-reshaper") as {
  convertArabic: (s: string) => string;
};
import bidiFactory from "bidi-js";

const bidi = bidiFactory();

export function prepareArabicForPdfLine(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return "";
  try {
    const shaped = ArabicReshaper.convertArabic(trimmed);
    const levels = bidi.getEmbeddingLevels(shaped, "rtl");
    return bidi.getReorderedString(shaped, levels);
  } catch {
    return trimmed;
  }
}
