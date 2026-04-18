// Phase 1: إغلاق الإعلانات العادية فقط (ليس الشاليه — لا حجوزات في هذه المرحلة).

import 'package:aqarai_app/constants/deal_constants.dart';

/// `properties.listingCategory`
abstract final class ListingCategory {
  static const String normal = 'normal';
  static const String chalet = 'chalet';
}

/// Write-time alignment: when Firestore `type` is [chalet], [listingCategory] must be [ListingCategory.chalet].
String listingCategoryForPropertyType(String? firestoreType) {
  final t = (firestoreType ?? '').toString().trim().toLowerCase();
  return t == ListingCategory.chalet ? ListingCategory.chalet : ListingCategory.normal;
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
  /// Awaiting main photo upload — not shown in public marketplace; admin cannot approve yet.
  static const String pendingUpload = 'pending_upload';

  /// Awaiting admin approval (`approved != true`); not a Firestore create default — used after data repair.
  static const String pendingApproval = 'pending_approval';

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

/// Chalet listing: [listingCategory] **or** Firestore `type == chalet` (compat).
bool listingDataIsChalet(Map<String, dynamic> d) {
  final cat = (d['listingCategory'] ?? '').toString().trim();
  if (cat == ListingCategory.chalet) return true;
  final propType = (d['type'] ?? '').toString().trim().toLowerCase();
  return propType == 'chalet';
}

/// Public marketplace discovery — **must match** [propertyPublicDiscovery] in Firestore rules.
///
/// Chalet slice: `type == chalet` **or** legacy `listingCategory == chalet`.
/// Normal slice: `listingCategory == normal` and `isActive == true`.
bool listingDataIsPubliclyDiscoverable(Map<String, dynamic> d) {
  if (d['approved'] != true) return false;
  final lifecycle = (d['status'] ?? ListingStatus.active).toString().trim();
  if (lifecycle == ListingStatus.pendingUpload ||
      lifecycle == ListingStatus.pendingApproval) {
    return false;
  }
  if (d['hiddenFromPublic'] != false) return false;
  final cat = (d['listingCategory'] ?? '').toString().trim();
  final propType = (d['type'] ?? '').toString().trim().toLowerCase();
  if (propType == ListingCategory.chalet || cat == ListingCategory.chalet) {
    return true;
  }
  if (cat == ListingCategory.normal) {
    return d['isActive'] == true;
  }
  return false;
}

bool listingDataCanSubmitClosure(Map<String, dynamic> d) {
  if (listingDataIsChalet(d)) return false;
  final st = (d['status'] ?? '').toString().trim();
  if (st == ListingStatus.pendingUpload || st == ListingStatus.pendingApproval) {
    return false;
  }
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

/// Owner must upload a main image (or retry) before the listing is treated as ready.
bool listingDataNeedsImageUpload(Map<String, dynamic> d) {
  final st = (d['status'] ?? ListingStatus.active).toString().trim();
  if (st == ListingStatus.pendingUpload) return true;
  final approved = d['approved'] == true;

  bool hasAnyImage() {
    if (d['hasImage'] == true) return true;
    final imgs = d['images'];
    return imgs is List && imgs.isNotEmpty;
  }

  // Approved listings must never show "re-upload" unless images are truly missing.
  if (approved) return !hasAnyImage();

  // For non-approved, keep "hasImage:false" as a strong hint for retry flows.
  if (hasAnyImage()) return false;
  if (d['hasImage'] == false) return true;
  return false;
}

/// True when the listing represents a completed transaction on the property doc.
/// `sold` / `rented` / `exchanged` must align with [DealStatus.closed] on the same
/// document (`properties.dealStatus` mirrors CRM closure); see [DealAdminService].
bool listingDataIsClosedDeal(Map<String, dynamic> d) {
  final st = (d['status'] ?? '').toString().trim();
  if (st == ListingStatus.inactive) return true;
  // Terminal sale/rent/exchange counts only when CRM pipeline closed the deal.
  if (st == ListingStatus.sold ||
      st == ListingStatus.rented ||
      st == ListingStatus.exchanged) {
    return (d['dealStatus'] ?? '').toString().trim() == DealStatus.closed;
  }
  return false;
}

/// عناوين عربية لشارة الحالة في «إعلاناتي».
String listingStatusLabelAr(Map<String, dynamic> d) {
  final st = (d['status'] ?? ListingStatus.active).toString().trim();
  switch (st) {
    case ListingStatus.pendingUpload:
      return 'بانتظار رفع الصورة';
    case ListingStatus.pendingApproval:
      return 'بانتظار الاعتماد';
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

/// Chip / badge for owner + marketplace cards (`ar` | non-`ar`).
String listingStatusChipLabel(Map<String, dynamic> d, String languageCode) {
  if (listingDataNeedsImageUpload(d)) {
    return languageCode == 'ar' ? 'بانتظار رفع الصورة' : 'Photo upload pending';
  }
  if (languageCode == 'ar') return listingStatusLabelAr(d);
  final st = (d['status'] ?? ListingStatus.active).toString().trim();
  switch (st) {
    case ListingStatus.pendingUpload:
      return 'Photo upload pending';
    case ListingStatus.pendingApproval:
      return 'Pending approval';
    case ListingStatus.pendingSaleConfirmation:
      return 'Pending sale';
    case ListingStatus.pendingRentConfirmation:
      return 'Pending rent';
    case ListingStatus.pendingExchangeConfirmation:
      return 'Pending deal';
    case ListingStatus.sold:
      return 'Sold';
    case ListingStatus.rented:
      return 'Rented';
    case ListingStatus.exchanged:
      return 'Exchanged';
    case ListingStatus.inactive:
      return 'Inactive';
    case ListingStatus.approvedLegacy:
    case ListingStatus.active:
    default:
      return 'Active';
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
