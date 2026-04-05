import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/listing_enums.dart';

/// Business logic for admin conversion, insights, and alerts (no Firestore I/O).
///
/// Data is prepared in the dashboard: bounded `deals` + `property_views` streams,
/// plus [analytics/global] scalars for totals and AI share.
abstract final class AdminIntelligenceService {
  static const List<String> canonicalSources = [
    DealLeadSource.aiChat,
    DealLeadSource.search,
    DealLeadSource.featured,
    DealLeadSource.direct,
    DealLeadSource.interestedButton,
    DealLeadSource.unknown,
  ];

  // ---------------------------------------------------------------------------
  // Conversion
  // ---------------------------------------------------------------------------

  /// Returns [deals] / [views], or `0.0` when [views] <= 0 (safe divide).
  static double calculateConversion(int views, int deals) {
    if (views <= 0) return 0.0;
    if (deals <= 0) return 0.0;
    return deals / views;
  }

  /// Counts [leadSource] occurrences on documents (views + deals both use same field).
  static Map<String, int> countByLeadSource(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final out = <String, int>{for (final s in canonicalSources) s: 0};
    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final k = _normalizeLeadSource(m['leadSource']);
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  /// Per-source conversion: deals(sample) ÷ views(sample) for each channel.
  static Map<String, double> calculateConversionBySource(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> deals,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> views,
  ) {
    final vc = countByLeadSource(views);
    final dc = countByLeadSource(deals);
    final out = <String, double>{};
    for (final s in canonicalSources) {
      out[s] = calculateConversion(vc[s] ?? 0, dc[s] ?? 0);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Insights (readable English; localize in UI if needed)
  // ---------------------------------------------------------------------------

  /// Rule-based messages; no duplicates; [aiPercentage] and [conversionRate] in 0–1.
  static List<String> generateInsights({
    required int totalDeals,
    required double aiPercentage,
    required double conversionRate,
  }) {
    final out = <String>[];

    if (totalDeals <= 0) {
      out.add(
        'No closed deals yet — metrics will appear after your first approvals.',
      );
      return out;
    }

    if (aiPercentage > 0.4) {
      out.add('AI is performing strongly');
    } else if (aiPercentage < 0.2) {
      out.add('AI needs optimization');
    }

    if (conversionRate < 0.05) {
      out.add('Low conversion rate — improve listings');
    } else if (conversionRate > 0.15) {
      out.add('High conversion performance');
    }

    return out;
  }

  // ---------------------------------------------------------------------------
  // Alerts
  // ---------------------------------------------------------------------------

  /// [todayAiPercentage] / [yesterdayAiPercentage] are AI deal share per day (0–1).
  /// Optional [conversionToday] / [conversionYesterday]: sample funnel deals÷views for that calendar day.
  static List<String> generateAlerts({
    required int todayDeals,
    required int yesterdayDeals,
    required double todayAiPercentage,
    required double yesterdayAiPercentage,
    double? conversionToday,
    double? conversionYesterday,
  }) {
    final out = <String>[];

    if (todayDeals == 0) {
      out.add('🚨 No deals recorded today');
    }

    if (yesterdayDeals > 0 && todayDeals < yesterdayDeals) {
      out.add('📉 Deals dropped compared to yesterday');
    }

    if (yesterdayDeals > 0 &&
        yesterdayAiPercentage > 0 &&
        todayAiPercentage < yesterdayAiPercentage) {
      out.add('📉 AI performance dropped');
    }

    if (conversionYesterday != null &&
        conversionToday != null &&
        conversionYesterday >= 0.02 &&
        conversionToday < conversionYesterday * 0.85) {
      out.add('📉 Conversion rate dropped vs yesterday');
    }

    return out;
  }

  // ---------------------------------------------------------------------------
  // Sample preparation (calendar = device local)
  // ---------------------------------------------------------------------------

  /// Metrics derived only from capped lists (lightweight, no extra queries).
  static DaySampleMetrics buildDaySampleMetrics({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> deals,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> views,
  }) {
    final now = DateTime.now();
    final startToday = DateTime(now.year, now.month, now.day);
    final startYesterday = startToday.subtract(const Duration(days: 1));
    var todayDeals = 0, yDeals = 0;
    var todayAi = 0, yAi = 0;
    var todayViews = 0, yViews = 0;

    for (final d in deals) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final t = _readTs(m['closedAt']);
      if (t == null) continue;
      final isAi =
          _normalizeLeadSource(m['leadSource']) == DealLeadSource.aiChat;

      if (!t.isBefore(startToday)) {
        todayDeals++;
        if (isAi) todayAi++;
      } else if (!t.isBefore(startYesterday) && t.isBefore(startToday)) {
        yDeals++;
        if (isAi) yAi++;
      }
    }

    for (final d in views) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final t = _readTs(m['viewedAt']);
      if (t == null) continue;
      if (!t.isBefore(startToday)) {
        todayViews++;
      } else if (!t.isBefore(startYesterday) && t.isBefore(startToday)) {
        yViews++;
      }
    }

    final todayAiPct = todayDeals > 0 ? todayAi / todayDeals : 0.0;
    final yAiPct = yDeals > 0 ? yAi / yDeals : 0.0;
    final convToday = calculateConversion(todayViews, todayDeals);
    final convY = calculateConversion(yViews, yDeals);

    return DaySampleMetrics(
      todayDeals: todayDeals,
      yesterdayDeals: yDeals,
      todayViews: todayViews,
      yesterdayViews: yViews,
      todayAiShare: todayAiPct,
      yesterdayAiShare: yAiPct,
      conversionTodaySample: convToday,
      conversionYesterdaySample: convY,
    );
  }
}

/// Local counts + ratios for alert rules (from streamed samples only).
class DaySampleMetrics {
  const DaySampleMetrics({
    required this.todayDeals,
    required this.yesterdayDeals,
    required this.todayViews,
    required this.yesterdayViews,
    required this.todayAiShare,
    required this.yesterdayAiShare,
    required this.conversionTodaySample,
    required this.conversionYesterdaySample,
  });

  final int todayDeals;
  final int yesterdayDeals;
  final int todayViews;
  final int yesterdayViews;
  final double todayAiShare;
  final double yesterdayAiShare;

  /// Views(today)÷deals(today) style funnel on the **sample** only.
  final double conversionTodaySample;
  final double conversionYesterdaySample;
}

String _normalizeLeadSource(dynamic raw) {
  final s = raw?.toString().trim() ?? '';
  if (s.isEmpty) return DealLeadSource.unknown;
  if (s == DealLeadSource.interestedButton) return DealLeadSource.interestedButton;
  if (DealLeadSource.isAttributionSource(s)) return s;
  return DealLeadSource.unknown;
}

DateTime? _readTs(dynamic v) {
  if (v is Timestamp) return v.toDate();
  return null;
}
