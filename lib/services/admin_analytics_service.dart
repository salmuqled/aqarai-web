import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/models/admin_analytics_models.dart';
import 'package:aqarai_app/models/notification_ab_models.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/analytics_service.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

/// Client-side aggregation of `deals` for the admin dashboard.
///
/// Firestore has no ad-hoc `GROUP BY`; we use **one bounded query** (newest first)
/// and derive breakdowns in memory to limit reads.
///
/// API surface:
/// - [getGlobalAnalytics] / [watchGlobalAnalytics] → `analytics/global`
/// - [watchDealsForDashboard] / [fetchDealsForDashboard] → capped `deals` list
/// - [getDealsBySource], [getDealsOverTime], [getDealsByArea], [getDealsByPropertyType] → pure reducers
class AdminAnalyticsService {
  AdminAnalyticsService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// Max documents loaded for detail sections (tune as catalog grows).
  static const int kDashboardDealsLimit = 1500;

  /// Recent property views for intelligence (conversion / source mix).
  static const int kDashboardViewsLimit = 2000;

  static const List<String> _canonicalSources = [
    DealLeadSource.aiChat,
    DealLeadSource.search,
    DealLeadSource.featured,
    DealLeadSource.direct,
    DealLeadSource.interestedButton,
    DealLeadSource.unknown,
  ];

  DocumentReference<Map<String, dynamic>> get _globalRef =>
      AnalyticsService.globalRef(_db);

  // --- Section 1: fast path (`analytics/global`) ---

  /// Single read of aggregated counters.
  Future<GlobalAnalyticsSnapshot> getGlobalAnalytics() async {
    final s = await _globalRef.get();
    return GlobalAnalyticsSnapshot.fromSnapshot(s);
  }

  /// Live updates for top cards + AI %.
  Stream<GlobalAnalyticsSnapshot> watchGlobalAnalytics() =>
      _globalRef.snapshots().map(GlobalAnalyticsSnapshot.fromSnapshot);

  // --- Shared deals query (one stream / one fetch for all breakdowns) ---

  Query<Map<String, dynamic>> get dealsQueryForDashboard => _db
      .collection('deals')
      .orderBy('createdAt', descending: true)
      .limit(kDashboardDealsLimit);

  Stream<QuerySnapshot<Map<String, dynamic>>> watchDealsForDashboard() =>
      dealsQueryForDashboard.snapshots();

  Future<QuerySnapshot<Map<String, dynamic>>> fetchDealsForDashboard() =>
      dealsQueryForDashboard.get();

  /// Latest views (one query; client-side grouping for funnel metrics).
  Query<Map<String, dynamic>> get viewsQueryForDashboard => _db
      .collection('property_views')
      .orderBy('viewedAt', descending: true)
      .limit(kDashboardViewsLimit);

  Stream<QuerySnapshot<Map<String, dynamic>>> watchViewsForDashboard() =>
      viewsQueryForDashboard.snapshots();

  // --- Pure aggregation (testable, no I/O) ---

  static double _money(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim()) ?? 0;
  }

  static DateTime? _closedAt(Map<String, dynamic> m) {
    final c = m['closedAt'];
    if (c is Timestamp) return c.toDate();
    return null;
  }

  /// Revenue for a deal row: prefer [finalPrice], else [listingPrice].
  static double _dealRevenue(Map<String, dynamic> m) {
    final fp = m['finalPrice'];
    if (fp != null) return _money(fp);
    return _money(m['listingPrice']);
  }

  static String _normalizeLeadSource(Map<String, dynamic> m) {
    final raw = m['leadSource']?.toString().trim();
    if (raw == null || raw.isEmpty) return DealLeadSource.unknown;
    if (raw == DealLeadSource.interestedButton) {
      return DealLeadSource.interestedButton;
    }
    if (DealLeadSource.isAttributionSource(raw)) return raw;
    return DealLeadSource.unknown;
  }

  /// Section 2 — one row per canonical source (zeros included).
  static List<SourceStats> getDealsBySource(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final agg = <String, _MoneyCount>{};
    for (final k in _canonicalSources) {
      agg[k] = _MoneyCount();
    }

    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final src = _normalizeLeadSource(m);
      final row = agg.putIfAbsent(src, _MoneyCount.new);
      row.count++;
      row.revenue += _dealRevenue(m);
      if (isFinalizedDeal(m)) {
        row.commission += getCommission(m);
      }
    }

    return _canonicalSources.map((k) {
      final a = agg[k] ?? _MoneyCount();
      return SourceStats(
        sourceKey: k,
        dealCount: a.count,
        totalRevenue: a.revenue,
        totalCommission: a.commission,
      );
    }).toList();
  }

  /// Section 3 — time buckets, ascending for charts.
  static List<TimeStats> getDealsOverTime(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    DealsTimeGrouping grouping,
  ) {
    final fmtDay = DateFormat('yyyy-MM-dd');
    final fmtMonth = DateFormat('yyyy-MM');

    final buckets = <String, _TimeBucket>{};

    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final dt = _closedAt(m);
      if (dt == null) continue;

      late String key;
      late String label;

      switch (grouping) {
        case DealsTimeGrouping.day:
          key = fmtDay.format(dt);
          label = key;
        case DealsTimeGrouping.week:
          // Week bucket = calendar week start (Monday), local time.
          final local = DateTime(dt.year, dt.month, dt.day);
          final monday = local.subtract(Duration(days: local.weekday - 1));
          key = fmtDay.format(monday);
          label = key;
        case DealsTimeGrouping.month:
          key = fmtMonth.format(dt);
          label = key;
      }

      final bucket = buckets.putIfAbsent(key, () => _TimeBucket(label: label));
      bucket.count++;
      bucket.revenue += _dealRevenue(m);
    }

    final sortedKeys = buckets.keys.toList()..sort();
    return sortedKeys
        .map(
          (k) => TimeStats(
            bucketKey: k,
            label: buckets[k]!.label,
            dealCount: buckets[k]!.count,
            totalRevenue: buckets[k]!.revenue,
          ),
        )
        .toList();
  }

  /// Section 4 — top N area composites by revenue.
  static List<AreaStats> getDealsByArea(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
    int topN = 5,
  }) {
    final map = <String, _AreaAgg>{};

    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final gov = (m['governorateAr'] ?? '').toString().trim();
      final area = (m['areaAr'] ?? '').toString().trim();
      final key = '$gov\t$area';
      final a = map.putIfAbsent(
        key,
        () => _AreaAgg(governorateAr: gov, areaAr: area),
      );
      a.dealCount++;
      a.totalRevenue += _dealRevenue(m);
    }

    final list =
        map.values
            .map(
              (a) => AreaStats(
                governorateAr: a.governorateAr,
                areaAr: a.areaAr,
                dealCount: a.dealCount,
                totalRevenue: a.totalRevenue,
              ),
            )
            .toList()
          ..sort((a, b) => b.totalRevenue.compareTo(a.totalRevenue));

    if (list.length <= topN) return list;
    return list.sublist(0, topN);
  }

  /// Section 5 — property type frequencies.
  static List<PropertyTypeStats> getDealsByPropertyType(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final counts = <String, int>{};

    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final t = (m['propertyType'] ?? '—').toString().trim();
      final key = t.isEmpty ? '—' : t;
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final list =
        counts.entries
            .map((e) => PropertyTypeStats(propertyType: e.key, count: e.value))
            .toList()
          ..sort((a, b) => b.count.compareTo(a.count));

    return list;
  }

  // --- Notification tracking (FCM logs + analytics/notification_totals) ---

  DocumentReference<Map<String, dynamic>> get notificationTotalsRef =>
      _db.collection('analytics').doc('notification_totals');

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchNotificationTotals() =>
      notificationTotalsRef.snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchRecentNotificationLogs() =>
      _db
          .collection('notification_logs')
          .orderBy('createdAt', descending: true)
          .limit(5)
          .snapshots();

  /// سجلات حديثة لحساب أفضل نسخة A/B (حد أقصى 100 وثيقة).
  Stream<QuerySnapshot<Map<String, dynamic>>> watchNotificationLogsForAb() =>
      _db
          .collection('notification_logs')
          .orderBy('createdAt', descending: true)
          .limit(100)
          .snapshots();

  /// أوزان التعلّم (`notification_learning`) لعرض لوحة «رؤى التعلّم».
  Stream<QuerySnapshot<Map<String, dynamic>>> watchNotificationLearning() =>
      _db.collection('notification_learning').snapshots();

  /// سجلات إشعارات حديثة لحساب التحويلات (صفقات مربوطة).
  Stream<QuerySnapshot<Map<String, dynamic>>>
      watchNotificationLogsForConversions() =>
          _db
              .collection('notification_logs')
              .orderBy('createdAt', descending: true)
              .limit(100)
              .snapshots();

  static int _notifInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }

  /// CTR = clicks / sent لكل نسخة؛ تُعاد أفضل نسخة في **أحدث** حملة لها نسختان على الأقل.
  static BestNotificationVariant? getBestNotificationVariant(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> logDocsNewestFirst,
  ) {
    final variantRows = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final d in logDocsNewestFirst) {
      final m = d.data();
      final cid = m['abCampaignId']?.toString().trim() ?? '';
      final vid = m['variantId']?.toString().trim() ?? '';
      if (cid.isEmpty || vid.isEmpty) continue;
      variantRows.add(d);
    }
    if (variantRows.isEmpty) return null;

    final campaignsOrder = <String>[];
    final seen = <String>{};
    for (final d in variantRows) {
      final cid = d.data()['abCampaignId'].toString();
      if (!seen.contains(cid)) {
        seen.add(cid);
        campaignsOrder.add(cid);
      }
    }

    for (final cid in campaignsOrder) {
      final group = variantRows
          .where((d) => d.data()['abCampaignId'].toString() == cid)
          .toList();
      if (group.length < 2) continue;

      BestNotificationVariant? best;
      for (final d in group) {
        final m = d.data();
        final sent = _notifInt(m['sentCount']);
        final clicks = _notifInt(m['clickCount']);
        if (sent <= 0) continue;
        final ctr = clicks / sent;
        final vt =
            (m['variantText'] ?? m['title'] ?? '').toString().trim();
        if (vt.isEmpty) continue;
        final vid = m['variantId'].toString();
        final candidate = BestNotificationVariant(
          variantText: vt,
          ctr: ctr,
          sentCount: sent,
          clickCount: clicks,
          variantId: vid,
          notificationLogId: d.id,
          abCampaignId: cid,
        );
        if (best == null ||
            ctr > best.ctr ||
            (ctr == best.ctr && sent > best.sentCount)) {
          best = candidate;
        }
      }
      if (best != null) return best;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Grouping enum (public for dashboard toggles)
// ---------------------------------------------------------------------------

enum DealsTimeGrouping { day, week, month }

class _MoneyCount {
  int count = 0;
  double revenue = 0;
  double commission = 0;
}

class _TimeBucket {
  _TimeBucket({required this.label});

  final String label;
  int count = 0;
  double revenue = 0;
}

class _AreaAgg {
  _AreaAgg({required this.governorateAr, required this.areaAr});

  final String governorateAr;
  final String areaAr;
  int dealCount = 0;
  double totalRevenue = 0;
}
