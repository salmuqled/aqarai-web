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
  static String inferMissingFromListingType(String listingType) {
    final t = _norm(listingType);
    if (t == 'chalet') return 'daily';
    if (legacyMonthlyTypes.contains(t)) return 'monthly';
    return 'full';
  }

  /// Reads stored [priceType] or infers from [listingType] slug (e.g. `chalet`).
  static String infer({String? stored, required String listingType}) {
    final s = _norm(stored);
    if (values.contains(s)) return s;
    return inferMissingFromListingType(listingType);
  }

  /// Auto value for new listings from [AddPropertyPage] (no manual override).
  static String forNewListing({
    required String propertyType,
    required String serviceType,
  }) {
    final t = _norm(propertyType);
    final svc = _norm(serviceType);
    if (t == 'chalet') return 'daily';
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
