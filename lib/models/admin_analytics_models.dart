import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/listing_enums.dart';

/// Snapshot of `analytics/global` (fast summary counters).
class GlobalAnalyticsSnapshot {
  GlobalAnalyticsSnapshot._(this.raw);

  final Map<String, dynamic>? raw;

  /// Before first snapshot or missing doc — safe zeros for UI.
  factory GlobalAnalyticsSnapshot.empty() => GlobalAnalyticsSnapshot._(null);

  static GlobalAnalyticsSnapshot fromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) => GlobalAnalyticsSnapshot._(snap.data());

  static num _n(Map<String, dynamic>? d, String key) {
    if (d == null) return 0;
    final v = d[key];
    if (v is num) return v;
    return num.tryParse(v?.toString() ?? '') ?? 0;
  }

  num get totalDeals => _n(raw, 'totalDeals');
  num get totalVolume => _n(raw, 'totalVolume');
  num get totalCommission => _n(raw, 'totalCommission');
  num get aiDeals => _n(raw, 'aiDeals');
  num get searchDeals => _n(raw, 'searchDeals');
  num get featuredDeals => _n(raw, 'featuredDeals');
  num get directDeals => _n(raw, 'directDeals');
  num get unknownDeals => _n(raw, 'unknownDeals');

  /// `aiDeals / totalDeals` when [totalDeals] > 0; else null (show "—").
  double? get aiDealShare {
    final td = totalDeals;
    if (td <= 0) return null;
    return (aiDeals / td).toDouble();
  }
}

/// Aggregated metrics for one `leadSource` bucket (from `deals` rows).
class SourceStats {
  const SourceStats({
    required this.sourceKey,
    required this.dealCount,
    required this.totalRevenue,
    required this.totalCommission,
  });

  final String sourceKey;
  final int dealCount;
  final double totalRevenue;
  final double totalCommission;

  String get displayLabel {
    switch (sourceKey) {
      case DealLeadSource.aiChat:
        return 'AI chat';
      case DealLeadSource.search:
        return 'Search';
      case DealLeadSource.featured:
        return 'Featured';
      case DealLeadSource.direct:
        return 'Direct';
      default:
        return 'Unknown';
    }
  }

  String get displayLabelAr {
    switch (sourceKey) {
      case DealLeadSource.aiChat:
        return 'الذكاء الاصطناعي';
      case DealLeadSource.search:
        return 'بحث';
      case DealLeadSource.featured:
        return 'مميز';
      case DealLeadSource.direct:
        return 'مباشر';
      default:
        return 'غير معروف';
    }
  }
}

/// One bucket for deals-over-time chart.
class TimeStats {
  const TimeStats({
    required this.bucketKey,
    required this.label,
    required this.dealCount,
    required this.totalRevenue,
  });

  /// Stable sort key (ISO-like).
  final String bucketKey;
  final String label;
  final int dealCount;
  final double totalRevenue;
}

/// Top geographic bucket from deals.
class AreaStats {
  const AreaStats({
    required this.governorateAr,
    required this.areaAr,
    required this.dealCount,
    required this.totalRevenue,
  });

  final String governorateAr;
  final String areaAr;
  final int dealCount;
  final double totalRevenue;

  String get compositeLabel {
    if (governorateAr.isEmpty && areaAr.isEmpty) return '—';
    if (governorateAr.isEmpty) return areaAr;
    if (areaAr.isEmpty) return governorateAr;
    return '$governorateAr — $areaAr';
  }
}

/// Count per property type from deals.
class PropertyTypeStats {
  const PropertyTypeStats({required this.propertyType, required this.count});

  final String propertyType;
  final int count;
}
