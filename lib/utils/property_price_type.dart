// Firestore field `priceType`: daily | monthly | yearly | full
// Missing field: infer from `type` (must match functions/src/agent_brain.ts).

/// Canonical values stored on `properties.priceType`.
abstract final class PropertyPriceType {
  static const Set<String> values = {'daily', 'monthly', 'yearly', 'full'};

  /// Same set as backend `LEGACY_MONTHLY_TYPES` for missing `priceType`.
  static const Set<String> legacyMonthlyTypes = {
    'apartment',
    'house',
    'villa',
    'office',
    'shop',
    'building',
  };

  static String _norm(String? s) => (s ?? '').trim().toLowerCase();

  /// When [stored] is missing/invalid, infer from [listingType] slug.
  ///
  /// For chalets the caller MUST pass the [chaletMode] (daily/monthly/sale) —
  /// a chalet booked monthly has a monthly price unit, a chalet for sale is
  /// `full`, and only a chalet rented by the night is `daily`. Omitting
  /// [chaletMode] falls back to `daily` for backwards compatibility but is
  /// considered a bug in the new call path (use [infer] instead).
  static String inferMissingFromListingType(
    String listingType, {
    String? chaletMode,
  }) {
    final t = _norm(listingType);
    if (t == 'chalet') {
      final m = _norm(chaletMode);
      if (m == 'sale') return 'full';
      if (m == 'monthly') return 'monthly';
      return 'daily';
    }
    if (legacyMonthlyTypes.contains(t)) return 'monthly';
    return 'full';
  }

  /// Reads stored [priceType] or infers from [listingType] slug (e.g. `chalet`).
  /// Pass [chaletMode] (from the listing document) so chalet-monthly / chalet-sale
  /// are correctly mapped when [stored] is missing or invalid.
  static String infer({
    String? stored,
    required String listingType,
    String? chaletMode,
  }) {
    final s = _norm(stored);
    if (values.contains(s)) {
      // Correct legacy bug: some chalet-monthly listings were persisted with
      // `priceType: "daily"` (old `forNewListing` default forced daily for
      // every chalet). When the listing's `chaletMode` says monthly, trust
      // the mode over the stale field so price display and ROI math stay
      // consistent.
      if (_norm(listingType) == 'chalet') {
        final m = _norm(chaletMode);
        if (m == 'monthly' && s == 'daily') return 'monthly';
        if (m == 'sale' && s != 'full') return 'full';
      }
      return s;
    }
    return inferMissingFromListingType(listingType, chaletMode: chaletMode);
  }

  /// Auto value for new listings from [AddPropertyPage] (no manual override).
  ///
  /// Pass [chaletMode] when the listing is a chalet so we distinguish:
  /// `daily` (nightly rent) → "daily", `monthly` → "monthly", `sale` → "full".
  /// Omitting it defaults to `daily` for backward compatibility.
  ///
  /// For [legacyMonthlyTypes] with `serviceType == rent`, pass [rentPriceCadence]
  /// (`daily` | `monthly` | `yearly`) so apartments/offices can be listed as
  /// nightly stays (`priceType` / `rentalType` = `daily`).
  static String forNewListing({
    required String propertyType,
    required String serviceType,
    String? chaletMode,
    String? rentPriceCadence,
  }) {
    final t = _norm(propertyType);
    final svc = _norm(serviceType);
    if (t == 'chalet') {
      final m = _norm(chaletMode);
      if (m == 'sale') return 'full';
      if (m == 'monthly') return 'monthly';
      return 'daily';
    }
    if (svc == 'rent' && legacyMonthlyTypes.contains(t)) {
      final c = _norm(rentPriceCadence);
      if (c == 'daily') return 'daily';
      if (c == 'yearly') return 'yearly';
      return 'monthly';
    }
    if (t == 'apartment' || t == 'house') return 'monthly';
    if (t == 'land') return 'full';
    if (svc == 'sale') return 'full';
    if (t == 'villa') return 'monthly';
    if (t == 'shop' || t == 'office' || t == 'building') return 'monthly';
    if (t == 'industrialland' || t == 'industrial_land') return 'full';
    return 'full';
  }

  /// English unit suffix after amount (e.g. `" / night"`).
  static String suffixEn(String priceType) {
    switch (_norm(priceType)) {
      case 'daily':
        return ' / night';
      case 'monthly':
        return ' / month';
      case 'yearly':
        return ' / year';
      case 'full':
      default:
        return '';
    }
  }

  /// Arabic unit suffix after amount.
  static String suffixAr(String priceType) {
    switch (_norm(priceType)) {
      case 'daily':
        return ' / ليلة';
      case 'monthly':
        return ' / شهر';
      case 'yearly':
        return ' / سنة';
      case 'full':
      default:
        return '';
    }
  }

  static String suffixForLocale(String priceType, {required bool isArabic}) =>
      isArabic ? suffixAr(priceType) : suffixEn(priceType);
}
