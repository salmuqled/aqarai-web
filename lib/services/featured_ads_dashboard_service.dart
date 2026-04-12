import 'package:cloud_firestore/cloud_firestore.dart';

enum FeaturedDashboardWindow { h24, d7, d30 }

class FeaturedAdsDashboardSnapshot {
  const FeaturedAdsDashboardSnapshot({
    required this.window,
    required this.totalRevenueKwd,
    required this.totalPurchases,
    required this.uniqueBuyers,
    required this.avgRevenuePerUserKwd,
    required this.mostPopularPlanDays,
    required this.plansCounts,
    required this.revenueSeries,
    required this.totalShown,
    required this.totalClicked,
    required this.totalConversions,
    required this.ctr,
    required this.conversionRate,
    required this.revenuePerSuggestionKwd,
    required this.aiRevenueKwd,
  });

  final FeaturedDashboardWindow window;

  // Financial (payment_logs)
  final double totalRevenueKwd;
  final int totalPurchases;
  final int uniqueBuyers;
  final double avgRevenuePerUserKwd;
  final int? mostPopularPlanDays;
  final Map<int, int> plansCounts; // durationDays -> count

  /// Revenue points in chronological order.
  final List<RevenuePoint> revenueSeries;

  // Conversion (feature_suggestion_events)
  final int totalShown;
  final int totalClicked;
  final int totalConversions;
  final double? ctr;
  final double? conversionRate;
  final double revenuePerSuggestionKwd;
  final double aiRevenueKwd;
}

class RevenuePoint {
  const RevenuePoint({required this.bucketStart, required this.revenueKwd});
  final DateTime bucketStart;
  final double revenueKwd;
}

/// Professional dashboard aggregation (client-side) for:
/// - Featured payments: `payment_logs` (action == featured_ad_payment)
/// - AI suggestion funnel: `feature_suggestion_events`
///
/// This intentionally uses bounded reads for charts; for large scale, move to
/// server-side daily aggregates.
class FeaturedAdsDashboardService {
  FeaturedAdsDashboardService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const String _paymentLogs = 'payment_logs';
  static const String _analytics = 'analytics';

  static const String _featuredAction = 'featured_ad_payment';

  static double _money(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim()) ?? 0;
  }

  static DateTime? _ts(dynamic v) => v is Timestamp ? v.toDate() : null;

  static DateTime _bucket(DateTime dt, FeaturedDashboardWindow w) {
    final local = dt.toLocal();
    switch (w) {
      case FeaturedDashboardWindow.h24:
        return DateTime(local.year, local.month, local.day, local.hour);
      case FeaturedDashboardWindow.d7:
      case FeaturedDashboardWindow.d30:
        return DateTime(local.year, local.month, local.day);
    }
  }

  Duration _duration(FeaturedDashboardWindow w) {
    switch (w) {
      case FeaturedDashboardWindow.h24:
        return const Duration(hours: 24);
      case FeaturedDashboardWindow.d7:
        return const Duration(days: 7);
      case FeaturedDashboardWindow.d30:
        return const Duration(days: 30);
    }
  }

  Future<FeaturedAdsDashboardSnapshot> load({
    required FeaturedDashboardWindow window,
  }) async {
    final start = Timestamp.fromDate(DateTime.now().subtract(_duration(window)));

    // ---- Financial: payment_logs ----
    final paySnap = await _db
        .collection(_paymentLogs)
        .where('action', isEqualTo: _featuredAction)
        .where('timestamp', isGreaterThanOrEqualTo: start)
        .orderBy('timestamp', descending: false)
        .limit(5000)
        .get();

    var revenue = 0.0;
    final buyers = <String>{};
    final planCounts = <int, int>{};
    final series = <DateTime, double>{};

    for (final d in paySnap.docs) {
      final m = d.data();
      final amt = _money(m['amountKwd']);
      revenue += amt;

      final by = (m['performedBy'] ?? '').toString().trim();
      if (by.isNotEmpty) buyers.add(by);

      final durRaw = m['durationDays'];
      final dur = durRaw is int ? durRaw : int.tryParse(durRaw?.toString() ?? '');
      if (dur != null && dur > 0) {
        planCounts[dur] = (planCounts[dur] ?? 0) + 1;
      }

      final ts = _ts(m['timestamp']);
      if (ts != null) {
        final b = _bucket(ts, window);
        series[b] = (series[b] ?? 0) + amt;
      }
    }

    int? mostPopularPlan;
    var mostCount = 0;
    planCounts.forEach((days, c) {
      if (c > mostCount) {
        mostCount = c;
        mostPopularPlan = days;
      }
    });

    final uniqueBuyers = buyers.length;
    final avgPerUser = uniqueBuyers == 0 ? 0.0 : revenue / uniqueBuyers;

    final seriesSortedKeys = series.keys.toList()..sort();
    final revenueSeries = seriesSortedKeys
        .map((k) => RevenuePoint(bucketStart: k, revenueKwd: series[k] ?? 0))
        .toList();

    // ---- Conversion: daily aggregates (analytics/ai_suggestions_YYYY-MM-DD) ----
    String yyyymmdd(DateTime d) {
      final y = d.year.toString().padLeft(4, '0');
      final m = d.month.toString().padLeft(2, '0');
      final day = d.day.toString().padLeft(2, '0');
      return '$y-$m-$day';
    }

    final now = DateTime.now();
    final startDt = now.subtract(_duration(window));
    final startDay = yyyymmdd(DateTime(startDt.year, startDt.month, startDt.day));
    final endDay = yyyymmdd(DateTime(now.year, now.month, now.day));

    final aggSnap = await _db
        .collection(_analytics)
        .where('kind', isEqualTo: 'ai_suggestions_day')
        .where('day', isGreaterThanOrEqualTo: startDay)
        .where('day', isLessThanOrEqualTo: endDay)
        .get();

    var shown = 0;
    var clicked = 0;
    var conversions = 0;
    var aiRevenue = 0.0;
    for (final d in aggSnap.docs) {
      final m = d.data();
      shown += (m['totalShown'] as num?)?.toInt() ?? 0;
      clicked += (m['totalClicked'] as num?)?.toInt() ?? 0;
      conversions += (m['totalConversions'] as num?)?.toInt() ?? 0;
      aiRevenue += _money(m['totalRevenue']);
    }

    final ctr = shown <= 0 ? null : clicked / shown;
    final convRate = clicked <= 0 ? null : conversions / clicked;
    final revPerSuggestion = shown <= 0 ? 0.0 : aiRevenue / shown;

    return FeaturedAdsDashboardSnapshot(
      window: window,
      totalRevenueKwd: revenue,
      totalPurchases: paySnap.docs.length,
      uniqueBuyers: uniqueBuyers,
      avgRevenuePerUserKwd: avgPerUser,
      mostPopularPlanDays: mostPopularPlan,
      plansCounts: planCounts,
      revenueSeries: revenueSeries,
      totalShown: shown,
      totalClicked: clicked,
      totalConversions: conversions,
      ctr: ctr,
      conversionRate: convRate,
      revenuePerSuggestionKwd: revPerSuggestion,
      aiRevenueKwd: aiRevenue,
    );
  }
}

