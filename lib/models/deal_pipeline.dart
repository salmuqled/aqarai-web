import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

/// CRM pipeline for `deals.dealStatus` (distinct from `status: sold` ledger flag).
abstract final class DealPipelineStatus {
  static const String dealNew = DealStatus.newLead;
  static const String contacted = DealStatus.contacted;
  static const String qualified = DealStatus.qualified;
  static const String booked = DealStatus.booked;
  static const String signed = DealStatus.signed;
  static const String closed = DealStatus.closed;
  static const String notInterested = DealStatus.notInterested;

  static const List<String> ordered = [
    DealStatus.newLead,
    DealStatus.contacted,
    DealStatus.qualified,
    DealStatus.booked,
    DealStatus.signed,
    DealStatus.notInterested,
    DealStatus.closed,
  ];

  /// Final deal price UI (listing vs agreed price).
  static bool showFinalPriceSection(String? pipeline) {
    final s = pipeline ?? DealStatus.booked;
    return s == DealStatus.booked ||
        s == DealStatus.signed ||
        s == DealStatus.closed;
  }

  /// Entering [signed] or [closed] requires a positive final price.
  static bool requiresFinalPrice(String target) {
    return target == DealStatus.signed || target == DealStatus.closed;
  }
}

/// Commission from **final** deal price only (matches in-app Terms).
abstract final class DealCommissionCalculator {
  /// Sale / exchange: 1%. Rent: half of [finalPrice] (one month rent → half month commission).
  static double compute({
    required double finalPrice,
    required String serviceType,
  }) {
    if (finalPrice <= 0) return 0;
    final t = serviceType.trim().toLowerCase();
    if (t == 'rent') {
      return finalPrice / 2;
    }
    return finalPrice * 0.01;
  }

  /// Maps service fields to `sale` or `rent` (aligned with [getServiceBucket]).
  static String normalizeServiceType(Map<String, dynamic> deal) {
    final b = getServiceBucket(deal);
    if (b == 'rent') return 'rent';
    return 'sale';
  }
}
