/// Precompiled whitespace matcher reused by [listingChaletName]. Hoisted to
/// the top level so we don't re-instantiate a `RegExp` on every call — this
/// helper runs once per list card / detail page / admin tile, and those can
/// easily fire hundreds of times during a single scroll.
final RegExp _whitespaceRegex = RegExp(r'\s+');

/// Returns the display title for a listing.
///
/// When the owner supplied an optional [chaletName] at creation time (stored as
/// `chaletName` on the Firestore document), that name wins and becomes the
/// primary title everywhere (list card, details page, booking widget, admin
/// review, etc.).
///
/// Otherwise we fall back to the historical `"$areaLabel • $typeLabel"` format,
/// so every existing listing keeps rendering exactly as it does today — zero
/// regression for pre-feature data.
///
/// Type-safe against malformed Firestore documents: a non-String `chaletName`
/// (e.g. an accidental number, map, null) is treated as absent and the
/// fallback is used. No runtime cast errors.
String listingDisplayTitle(
  Map<String, dynamic> data, {
  required String areaLabel,
  required String typeLabel,
}) {
  // Single source of truth: all normalization (type check, trim, whitespace
  // safety) lives in [listingChaletName]. This function only decides
  // "name vs fallback".
  final name = listingChaletName(data);
  if (name.isNotEmpty) return name;
  return '$areaLabel • $typeLabel';
}

/// Convenience: trimmed chalet name, or empty string when absent. Callers that
/// need to conditionally render a name-specific UI (e.g. "name above subtitle")
/// should use this instead of re-implementing the null/empty dance.
///
/// Type-safe: a non-String value (null, number, map, list) returns `''`
/// without throwing, so this is safe to call on any Firestore document.
///
/// Whitespace-safe: inputs that are visually empty — e.g. `"   "`, `"\n\n"`,
/// `"\t "` — are normalized to `''` so they never produce an empty-looking
/// "bold" title in the UI.
String listingChaletName(Map<String, dynamic> data) {
  final raw = data['chaletName'];
  if (raw is! String) return '';
  final trimmed = raw.trim();
  // Defense-in-depth: catch whitespace that `String.trim()` might miss
  // (e.g. unusual Unicode whitespace). If the string has no non-whitespace
  // characters at all, treat it as absent.
  if (trimmed.replaceAll(_whitespaceRegex, '').isEmpty) return '';
  return trimmed;
}
