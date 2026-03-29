import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/services/notification_time_service.dart';

/// شرائح الجمهور من `activity_stats/global` (أعداد مستخدمي FCM فقط — مُجمَّعة على السيرفر).
class AudienceAnalysisResult {
  const AudienceAnalysisResult({
    required this.activeCount,
    required this.warmCount,
    required this.coldCount,
    required this.recommendedSegment,
    required this.recommendedSize,
    required this.confidence,
  });

  final int activeCount;
  final int warmCount;
  final int coldCount;

  /// `active` | `warm` | `cold` | `all`
  final String recommendedSegment;
  final int recommendedSize;
  final double confidence;
}

abstract final class NotificationAudienceService {
  static double ctrMultiplier(String segment) {
    switch (segment) {
      case 'active':
        return 1.22;
      case 'warm':
        return 1.0;
      case 'cold':
        return 0.62;
      default:
        return 1.0;
    }
  }

  static int _intField(Map<String, dynamic> m, String k) {
    final v = m[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// يقرأ `active7d` / `warm30d` / `cold` / `usersWithFcmTotal` فقط.
  static Future<AudienceAnalysisResult> getBestAudience(
    FirebaseFirestore db,
  ) async {
    try {
      final snap = await db.doc(kActivityStatsGlobalPath).get();
      if (!snap.exists) {
        return const AudienceAnalysisResult(
          activeCount: 0,
          warmCount: 0,
          coldCount: 0,
          recommendedSegment: 'active',
          recommendedSize: 0,
          confidence: 0.38,
        );
      }

      final m = snap.data()!;
      final active = _intField(m, 'active7d');
      final warm = _intField(m, 'warm30d');
      final cold = _intField(m, 'cold');
      final totalFcm = _intField(m, 'usersWithFcmTotal');
      final scanned = _intField(m, 'activityDocsScanned');

      String segment;
      int size;
      if (active >= 15) {
        segment = 'active';
        size = active;
      } else if (active + warm >= 25) {
        segment = 'warm';
        size = warm;
      } else if (cold >= 10) {
        segment = 'cold';
        size = cold;
      } else {
        segment = 'all';
        final sum = active + warm + cold;
        size = totalFcm > 0 ? totalFcm : sum;
      }

      var confidence = 0.58;
      if (scanned > 400) {
        confidence += 0.1;
      } else if (scanned < 30) {
        confidence -= 0.12;
      }
      if (segment == 'all') {
        confidence -= 0.08;
      }
      confidence = confidence.clamp(0.38, 0.9);

      return AudienceAnalysisResult(
        activeCount: active,
        warmCount: warm,
        coldCount: cold,
        recommendedSegment: segment,
        recommendedSize: size,
        confidence: confidence,
      );
    } catch (_) {
      return const AudienceAnalysisResult(
        activeCount: 0,
        warmCount: 0,
        coldCount: 0,
        recommendedSegment: 'active',
        recommendedSize: 0,
        confidence: 0.38,
      );
    }
  }
}
