// Phase 1: إغلاق الإعلانات العادية فقط (ليس الشاليه — لا حجوزات في هذه المرحلة).

/// `properties.listingCategory`
abstract final class ListingCategory {
  static const String normal = 'normal';
  static const String chalet = 'chalet';
}

/// `properties.chaletMode` — only when [listingCategory] is [ListingCategory.chalet].
///
/// Missing/unknown values are treated as [daily] for backward compatibility.
abstract final class ChaletMode {
  static const String daily = 'daily';
  static const String monthly = 'monthly';
  static const String sale = 'sale';
}

/// Firestore `properties.chaletMode` fragment for UI / reads.
///
/// [chaletMode] is null when the field is missing, empty, non-chalet, or not one of
/// [ChaletMode] values — [effectiveChaletMode] then falls back to [ChaletMode.daily].
class PropertyListingChaletMode {
  const PropertyListingChaletMode({this.chaletMode});

  final String? chaletMode;

  String get effectiveChaletMode => chaletMode ?? ChaletMode.daily;

  factory PropertyListingChaletMode.fromListingData(Map<String, dynamic> d) {
    if (!listingDataIsChalet(d)) {
      return const PropertyListingChaletMode();
    }
    final raw = (d['chaletMode'] ?? '').toString().trim().toLowerCase();
    if (raw.isEmpty) return const PropertyListingChaletMode();
    if (raw == ChaletMode.daily ||
        raw == ChaletMode.monthly ||
        raw == ChaletMode.sale) {
      return PropertyListingChaletMode(chaletMode: raw);
    }
    return const PropertyListingChaletMode();
  }
}

/// Normalized chalet mode; defaults to [ChaletMode.daily] for legacy chalet documents.
/// For non-chalet maps, returns empty string (callers should not treat as daily).
String effectiveChaletMode(Map<String, dynamic> d) {
  if (!listingDataIsChalet(d)) return '';
  final raw = (d['chaletMode'] ?? '').toString().trim().toLowerCase();
  if (raw.isEmpty) return ChaletMode.daily;
  if (raw == ChaletMode.monthly ||
      raw == ChaletMode.sale ||
      raw == ChaletMode.daily) {
    return raw;
  }
  return ChaletMode.daily;
}

/// Nightly calendar booking is only for chalets with [ChaletMode.daily] (or omitted mode).
bool listingDataChaletAllowsDailyBooking(Map<String, dynamic> d) {
  if (!listingDataIsChalet(d)) return false;
  return effectiveChaletMode(d) == ChaletMode.daily;
}

/// `properties.status`
abstract final class ListingStatus {
  static const String active = 'active';
  static const String approvedLegacy = 'approved';

  static const String pendingSaleConfirmation = 'pending_sale_confirmation';
  static const String pendingRentConfirmation = 'pending_rent_confirmation';
  static const String pendingExchangeConfirmation =
      'pending_exchange_confirmation';

  static const String sold = 'sold';
  static const String rented = 'rented';
  static const String exchanged = 'exchanged';

  /// احتياطي لعقارات أُغلقت دون قيمة exchanged
  static const String inactive = 'inactive';
}

abstract final class CloseRequestType {
  static const String sale = 'sale';
  static const String rent = 'rent';
  static const String exchange = 'exchange';
}

abstract final class ClosureRequestStatus {
  static const String pending = 'pending';
  static const String approved = 'approved';
  static const String rejected = 'rejected';
}

abstract final class DealType {
  static const String sale = 'sale';
  static const String rent = 'rent';
  static const String exchange = 'exchange';
}

abstract final class DealLeadSource {
  static const String aiChat = 'ai_chat';
  static const String search = 'search';
  static const String featured = 'featured';
  static const String direct = 'direct';

  /// "I'm interested" button flow (`deals` only — replaces legacy `interested_leads`).
  static const String interestedButton = 'interested_button';
  static const String unknown = 'unknown';

  /// Values allowed on `property_views` and when opening property details.
  static bool isAttributionSource(String s) {
    switch (s) {
      case aiChat:
      case search:
      case featured:
      case direct:
        return true;
      default:
        return false;
    }
  }

  /// Safe default for navigation when callers omit or pass an unexpected value.
  static String normalizeAttributionSource(String? raw) {
    final t = (raw ?? '').trim();
    return isAttributionSource(t) ? t : direct;
  }
}

/// Chalet listing — **only** [listingCategory] (no `type` fallback).
bool listingDataIsChalet(Map<String, dynamic> d) {
  final cat = (d['listingCategory'] ?? '').toString().trim();
  return cat == ListingCategory.chalet;
}

/// Public marketplace discovery — **must match** [propertyPublicDiscovery] in Firestore rules.
///
/// Uses only: [approved], [listingCategory], [isActive] (normal only), [hiddenFromPublic].
/// Does **not** use [status] or [type].
bool listingDataIsPubliclyDiscoverable(Map<String, dynamic> d) {
  if (d['approved'] != true) return false;
  if (d['hiddenFromPublic'] != false) return false;
  final cat = (d['listingCategory'] ?? '').toString().trim();
  if (cat == ListingCategory.chalet) return true;
  if (cat == ListingCategory.normal) {
    return d['isActive'] == true;
  }
  return false;
}

bool listingDataCanSubmitClosure(Map<String, dynamic> d) {
  if (listingDataIsChalet(d)) return false;
  if (d['approved'] != true) return false;
  if (d['closeRequestSubmitted'] == true) return false;
  if (d['hiddenFromPublic'] != false) return false;
  if (d['isActive'] != true) return false;
  if ((d['listingCategory'] ?? '').toString().trim() !=
      ListingCategory.normal) {
    return false;
  }
  return true;
}

bool listingDataIsClosedDeal(Map<String, dynamic> d) {
  final st = (d['status'] ?? '').toString();
  return st == ListingStatus.sold ||
      st == ListingStatus.rented ||
      st == ListingStatus.exchanged ||
      st == ListingStatus.inactive;
}

/// عناوين عربية لشارة الحالة في «إعلاناتي».
String listingStatusLabelAr(Map<String, dynamic> d) {
  final st = (d['status'] ?? ListingStatus.active).toString().trim();
  switch (st) {
    case ListingStatus.pendingSaleConfirmation:
      return 'بانتظار اعتماد البيع';
    case ListingStatus.pendingRentConfirmation:
      return 'بانتظار اعتماد التأجير';
    case ListingStatus.pendingExchangeConfirmation:
      return 'بانتظار اعتماد الصفقة';
    case ListingStatus.sold:
      return 'تم البيع';
    case ListingStatus.rented:
      return 'تم التأجير';
    case ListingStatus.exchanged:
      return 'تمت الصفقة';
    case ListingStatus.inactive:
      return 'غير نشط';
    case ListingStatus.approvedLegacy:
    case ListingStatus.active:
    default:
      return 'نشط';
  }
}

String closureButtonLabelAr(String serviceType) {
  switch (serviceType.toLowerCase().trim()) {
    case 'rent':
      return 'تم التأجير';
    case 'exchange':
      return 'تمت الصفقة';
    case 'sale':
    default:
      return 'تم البيع';
  }
}

String closeRequestTypeForServiceType(String? serviceType) {
  switch ((serviceType ?? 'sale').toLowerCase().trim()) {
    case 'rent':
      return CloseRequestType.rent;
    case 'exchange':
      return CloseRequestType.exchange;
    case 'sale':
    default:
      return CloseRequestType.sale;
  }
}

String pendingStatusForRequestType(String requestType) {
  switch (requestType) {
    case CloseRequestType.rent:
      return ListingStatus.pendingRentConfirmation;
    case CloseRequestType.exchange:
      return ListingStatus.pendingExchangeConfirmation;
    case CloseRequestType.sale:
    default:
      return ListingStatus.pendingSaleConfirmation;
  }
}

String finalStatusForRequestType(String requestType) {
  switch (requestType) {
    case CloseRequestType.rent:
      return ListingStatus.rented;
    case CloseRequestType.exchange:
      return ListingStatus.exchanged;
    case CloseRequestType.sale:
    default:
      return ListingStatus.sold;
  }
}

/// عنوان للعرض في طلب الإغلاق والأدمن.
String listingDisplayTitleFromProperty(Map<String, dynamic> d) {
  final t = d['title']?.toString().trim();
  if (t != null && t.isNotEmpty) return t;
  final area = (d['areaAr'] ?? d['area'] ?? '').toString().trim();
  final gov = (d['governorateAr'] ?? d['governorate'] ?? '').toString().trim();
  final parts = <String>[if (gov.isNotEmpty) gov, if (area.isNotEmpty) area];
  return parts.isEmpty ? '—' : parts.join(' · ');
}
