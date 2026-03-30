import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/caption_performance.dart';

/// Reads [caption_usage_logs] + [caption_clicks] (bounded) to compute per-variant CTR.
class CaptionPerformanceService {
  CaptionPerformanceService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const int _sampleLimit = 2000;

  static const List<String> kVariantIds = ['A', 'B', 'C'];

  /// Per-variant clicks, impressions (usage count), and CTR.
  Future<List<CaptionPerformance>> getPerformance() async {
    final impressions = <String, int>{for (final k in kVariantIds) k: 0};
    final clicks = <String, int>{for (final k in kVariantIds) k: 0};

    try {
      final usage = await _db
          .collection('caption_usage_logs')
          .orderBy('createdAt', descending: true)
          .limit(_sampleLimit)
          .get();
      for (final d in usage.docs) {
        final id = (d.data()['captionId'] ?? '').toString().trim().toUpperCase();
        if (impressions.containsKey(id)) {
          impressions[id] = (impressions[id] ?? 0) + 1;
        }
      }
    } catch (_) {}

    try {
      final clickSnap = await _db
          .collection('caption_clicks')
          .orderBy('clickedAt', descending: true)
          .limit(_sampleLimit)
          .get();
      for (final d in clickSnap.docs) {
        final id = (d.data()['captionId'] ?? '').toString().trim().toUpperCase();
        if (clicks.containsKey(id)) {
          clicks[id] = (clicks[id] ?? 0) + 1;
        }
      }
    } catch (_) {}

    final out = <CaptionPerformance>[];
    for (final id in kVariantIds) {
      final imp = impressions[id] ?? 0;
      final cl = clicks[id] ?? 0;
      final ctr = cl / (imp > 0 ? imp : 1);
      out.add(
        CaptionPerformance(
          captionId: id,
          clicks: cl,
          impressions: imp,
          ctr: ctr,
        ),
      );
    }
    out.sort((a, b) {
      final c = b.clicks.compareTo(a.clicks);
      if (c != 0) return c;
      return a.captionId.compareTo(b.captionId);
    });
    return out;
  }

  /// Map for [CaptionVariantService] (`A`/`B`/`C` → CTR).
  Future<Map<String, double>> getHistoricalCtrByVariant() async {
    final rows = await getPerformance();
    return {for (final r in rows) r.captionId: r.ctr};
  }
}
