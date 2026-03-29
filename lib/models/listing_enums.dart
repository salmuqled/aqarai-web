// Phase 1: إغلاق الإعلانات العادية فقط (ليس الشاليه — لا حجوزات في هذه المرحلة).

/// `properties.listingCategory`
abstract final class ListingCategory {
  static const String normal = 'normal';
  static const String chalet = 'chalet';
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

/// شاليه: لا يُعرض زر إغلاق المرحلة 1 (حجوزات لاحقاً).
bool listingDataIsChalet(Map<String, dynamic> d) {
  final cat = (d['listingCategory'] ?? '').toString().toLowerCase().trim();
  if (cat == ListingCategory.chalet) return true;
  final t = (d['type'] ?? '').toString().toLowerCase().trim();
  return t == 'chalet';
}

bool listingDataIsPubliclyDiscoverable(Map<String, dynamic> d) {
  if (d['approved'] != true) return false;
  if (d['hiddenFromPublic'] == true) return false;

  final raw = d['status'];
  if (raw == null) return true;
  final st = raw.toString().trim();
  if (st.isEmpty) return true;
  return st == ListingStatus.active || st == ListingStatus.approvedLegacy;
}

bool listingDataCanSubmitClosure(Map<String, dynamic> d) {
  if (listingDataIsChalet(d)) return false;
  if (d['approved'] != true) return false;
  if (d['closeRequestSubmitted'] == true) return false;

  final st = (d['status'] ?? ListingStatus.active).toString().trim();
  return st == ListingStatus.active || st == ListingStatus.approvedLegacy;
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
