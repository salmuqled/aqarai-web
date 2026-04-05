import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:aqarai_app/services/analytics_service.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

/// **Manual-only** rebuild of selected `analytics/global` fields from all `deals`
/// (paginated). Does not change Firestore schema; merges into the existing doc.
///
/// Recomputes from all `deals` (paginated):
/// - **totalVolume**: sum of `finalPrice` for every finalized deal ([isFinalizedDeal])
/// - **totalCommission** / **totalDeals**: finalized deals with commission > 0 only
///
/// Merges into `analytics/global`; does not touch per-source counters.
abstract final class AnalyticsBackfillService {
  AnalyticsBackfillService._();

  static const int _pageSize = 300;

  static double _money(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim()) ?? 0;
  }

  /// Walks every deal (`orderBy createdAt`), then writes `totalVolume`,
  /// `totalCommission`, and `totalDeals` once to [AnalyticsService.globalRef].
  static Future<void> recalculateGlobalAnalytics({
    FirebaseFirestore? firestore,
  }) async {
    final db = firestore ?? FirebaseFirestore.instance;

    var totalVolume = 0.0;
    var totalCommission = 0.0;
    var totalDeals = 0;
    var pages = 0;
    var docsScanned = 0;

    QueryDocumentSnapshot<Map<String, dynamic>>? cursor;
    final base = db.collection('deals').orderBy('createdAt');

    while (true) {
      Query<Map<String, dynamic>> q = base.limit(_pageSize);
      if (cursor != null) {
        q = q.startAfterDocument(cursor);
      }

      final snap = await q.get();
      if (snap.docs.isEmpty) break;

      pages++;
      docsScanned += snap.docs.length;

      for (final d in snap.docs) {
        Map<String, dynamic> m;
        try {
          m = d.data();
        } catch (_) {
          continue;
        }
        if (!isFinalizedDeal(m)) continue;
        final volume = _money(m['finalPrice']);
        totalVolume += volume;

        final comm = getCommission(m);
        if (comm <= 0) continue;
        totalCommission += comm;
        totalDeals += 1;
      }

      debugPrint(
        'Analytics backfill: page $pages, scanned $docsScanned docs, '
        'volume ${totalVolume.toStringAsFixed(2)} KWD, '
        '$totalDeals commission deals, '
        '${totalCommission.toStringAsFixed(2)} KWD commission',
      );

      cursor = snap.docs.last;
      if (snap.docs.length < _pageSize) break;
    }

    await AnalyticsService.globalRef(db).set(
      {
        'totalVolume': totalVolume,
        'totalCommission': totalCommission,
        'totalDeals': totalDeals,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    debugPrint(
      'Backfill complete: volume ${totalVolume.toStringAsFixed(2)} KWD, '
      '$totalDeals commission deals, ${totalCommission.toStringAsFixed(2)} KWD commission',
    );
  }
}
