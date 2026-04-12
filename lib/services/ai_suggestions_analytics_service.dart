import 'package:cloud_firestore/cloud_firestore.dart';

class AiSuggestionAnalyticsSnapshot {
  const AiSuggestionAnalyticsSnapshot({
    required this.totalShown,
    required this.totalClicked,
    required this.totalConversions,
    required this.totalRevenueKwd,
    required this.topSuggestionType,
    required this.topSuggestionTypeRevenueKwd,
  });

  final int totalShown;
  final int totalClicked;
  final int totalConversions;
  final double totalRevenueKwd;

  /// Highest-revenue suggestionType within window, or null when none.
  final String? topSuggestionType;
  final double topSuggestionTypeRevenueKwd;

  double? get ctr => totalShown <= 0 ? null : totalClicked / totalShown;
  double? get conversionRate =>
      totalClicked <= 0 ? null : totalConversions / totalClicked;

  double get revenuePerShown =>
      totalShown <= 0 ? 0.0 : totalRevenueKwd / totalShown;
}

/// Admin-only analytics for AI suggestions.
///
/// Scalable path: read daily aggregates from `analytics/ai_suggestions_YYYY-MM-DD`
/// (written by Cloud Functions).
class AiSuggestionsAnalyticsService {
  AiSuggestionsAnalyticsService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _analytics =>
      _db.collection('analytics');

  static String _yyyymmdd(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static double _money(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim()) ?? 0;
  }

  Future<AiSuggestionAnalyticsSnapshot> load({
    required Duration window,
  }) async {
    final now = DateTime.now();
    final startDt = now.subtract(window);
    final startDay = _yyyymmdd(DateTime(startDt.year, startDt.month, startDt.day));
    final endDay = _yyyymmdd(DateTime(now.year, now.month, now.day));

    final snap = await _analytics
        .where('kind', isEqualTo: 'ai_suggestions_day')
        .where('day', isGreaterThanOrEqualTo: startDay)
        .where('day', isLessThanOrEqualTo: endDay)
        .get();

    var shown = 0;
    var clicked = 0;
    var conversions = 0;
    var revenue = 0.0;

    final byTypeRevenue = <String, double>{};

    for (final d in snap.docs) {
      final m = d.data();
      shown += (m['totalShown'] as num?)?.toInt() ?? 0;
      clicked += (m['totalClicked'] as num?)?.toInt() ?? 0;
      conversions += (m['totalConversions'] as num?)?.toInt() ?? 0;
      revenue += _money(m['totalRevenue']);

      final by = m['bySuggestionType'];
      if (by is Map) {
        for (final entry in by.entries) {
          final key = entry.key.toString().trim();
          final val = entry.value;
          if (val is Map) {
            byTypeRevenue[key] =
                (byTypeRevenue[key] ?? 0) + _money(val['revenue']);
          }
        }
      }
    }

    String? topType;
    var topRev = 0.0;
    for (final e in byTypeRevenue.entries) {
      if (e.value > topRev) {
        topRev = e.value;
        topType = e.key;
      }
    }

    return AiSuggestionAnalyticsSnapshot(
      totalShown: shown,
      totalClicked: clicked,
      totalConversions: conversions,
      totalRevenueKwd: revenue,
      topSuggestionType: topType,
      topSuggestionTypeRevenueKwd: topRev,
    );
  }
}

