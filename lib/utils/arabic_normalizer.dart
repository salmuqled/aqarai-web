// lib/utils/arabic_normalizer.dart

/// Collapses the commonly-confused Arabic letter variants (أ / إ / آ).
/// Hoisted to the top level so we don't instantiate a new [RegExp] on every
/// keystroke — [normalizeArabic] runs once per save AND on every search-input
/// rebuild, so the hot path can fire many times per second while typing.
final RegExp _alefVariantsRegex = RegExp(r'[أإآ]');

/// Arabic tashkeel / diacritics block (fatha, kasra, damma, sukun, shadda,
/// tanweens — Unicode range U+064B..U+0652). Stripped so users don't need to
/// type diacritics to match stored names that might (or might not) contain them.
final RegExp _diacriticsRegex = RegExp(r'[\u064B-\u0652]');

/// Any run of whitespace (spaces, tabs, newlines, full-width spaces). Removed so
/// "شاليه اللؤلؤة" and "شاليهاللؤلؤة" both normalize to the same value.
final RegExp _whitespaceRegex = RegExp(r'\s+');

/// Canonical Arabic-aware normalization used for BOTH indexing (stored as
/// `chaletNameSearch` on the Firestore document at write-time) and querying
/// (applied to the user's input before running the Firestore range filter).
///
/// The two sides of the comparison MUST run the exact same normalization —
/// that's the entire point of this helper. If you need to extend it, update
/// both the save site ([add_property_page.dart]) and the query site
/// ([search_box.dart]) in the same change, and backfill existing docs.
///
/// Rules applied (in order):
///   1. Lowercase English letters (Arabic is caseless — a no-op on Arabic).
///   2. Collapse alef variants أ / إ / آ → ا
///   3. ؤ → و,  ئ → ي,  ة → ه
///   4. Strip tashkeel (U+064B..U+0652)
///   5. Strip ALL whitespace
///   6. Trim (safety net — after whitespace strip, always no-op, but cheap)
String normalizeArabic(String input) {
  String output = input.toLowerCase();

  output = output
      .replaceAll(_alefVariantsRegex, 'ا')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي')
      .replaceAll('ة', 'ه');

  output = output.replaceAll(_diacriticsRegex, '');
  output = output.replaceAll(_whitespaceRegex, '');

  return output.trim();
}
