import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/services/instagram_caption_service.dart';

/// Result of [AreaAnalyticsService.getAreaAnalytics] for caption + admin UI.
class AreaAnalyticsResult {
  const AreaAnalyticsResult({
    required this.recentDeals,
    required this.demandLevel,
  });

  /// Closed deals in this area within the last 7 days (`deals.closedAt`).
  final int recentDeals;

  /// `high` | `medium` | `low` — from deal volume, optionally boosted by views.
  final String demandLevel;

  InstagramDemandLevel get instagramDemandLevel {
    switch (demandLevel) {
      case 'high':
        return InstagramDemandLevel.high;
      case 'low':
        return InstagramDemandLevel.low;
      default:
        return InstagramDemandLevel.medium;
    }
  }
}

/// Reads `deals` (and optionally `property_views` + `properties`) to infer area demand.
class AreaAnalyticsService {
  AreaAnalyticsService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const int dealsLookbackDays = 7;
  static const int viewsLookbackDays = 3;

  /// Total views across sampled listings in [viewsLookbackDays] → one-step demand boost.
  static const int viewsHighThreshold = 25;

  /// Cap property IDs when correlating views to an area (read bounded).
  static const int maxPropertyIdsForViewSample = 30;

  static const int _whereInChunk = 30;

  /// Fallback: medium demand, 0 deals (also used on error / empty area).
  static const AreaAnalyticsResult kFallback = AreaAnalyticsResult(
    recentDeals: 0,
    demandLevel: 'medium',
  );

  Future<AreaAnalyticsResult> getAreaAnalytics(String area) async {
    final trimmed = area.trim();
    if (trimmed.isEmpty) return kFallback;

    final weekAgo = DateTime.now().subtract(
      const Duration(days: dealsLookbackDays),
    );
    final from = Timestamp.fromDate(weekAgo);

    final dealsAgg = await _db
        .collection('deals')
        .where('areaAr', isEqualTo: trimmed)
        .where('closedAt', isGreaterThanOrEqualTo: from)
        .count()
        .get();

    final recentDeals = dealsAgg.count ?? 0;
    var demand = _demandFromDealCount(recentDeals);

    try {
      if (await _viewsHighForArea(trimmed)) {
        demand = _upgradeDemandOneStep(demand);
      }
    } catch (_) {
      // Optional boost — ignore Firestore/index errors.
    }

    return AreaAnalyticsResult(recentDeals: recentDeals, demandLevel: demand);
  }

  static String _demandFromDealCount(int recentDeals) {
    if (recentDeals >= 10) return 'high';
    if (recentDeals >= 4) return 'medium';
    return 'low';
  }

  static String _upgradeDemandOneStep(String demand) {
    switch (demand) {
      case 'low':
        return 'medium';
      case 'medium':
        return 'high';
      default:
        return 'high';
    }
  }

  Future<bool> _viewsHighForArea(String areaAr) async {
    final props = await _db
        .collection('properties')
        .where('areaAr', isEqualTo: areaAr)
        .limit(maxPropertyIdsForViewSample)
        .get();

    if (props.docs.isEmpty) return false;

    final ids = props.docs.map((d) => d.id).toList();
    final threeDaysAgo = DateTime.now().subtract(
      const Duration(days: viewsLookbackDays),
    );
    final from = Timestamp.fromDate(threeDaysAgo);

    var totalViews = 0;
    for (var i = 0; i < ids.length; i += _whereInChunk) {
      final chunk = ids.sublist(i, math.min(i + _whereInChunk, ids.length));
      final snap = await _db
          .collection('property_views')
          .where('propertyId', whereIn: chunk)
          .where('viewedAt', isGreaterThanOrEqualTo: from)
          .count()
          .get();
      totalViews += snap.count ?? 0;
    }

    return totalViews >= viewsHighThreshold;
  }
}
