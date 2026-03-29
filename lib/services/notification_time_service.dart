import 'package:cloud_firestore/cloud_firestore.dart';

/// مسار المستند المُجمَّع من [updateActivityStats] (سيرفر).
const String kActivityStatsGlobalPath = 'activity_stats/global';

/// نتيجة تحليل أفضل ساعة إرسال من `activity_stats/global` (بدون مسح `user_activity` من العميل).
class BestSendTimeResult {
  const BestSendTimeResult({
    required this.bestHour,
    required this.confidence,
    required this.sampleSize,
  });

  /// 0–23 من الهيستوغرام المُجمَّع.
  final int bestHour;
  final double confidence;
  final int sampleSize;
}

abstract final class NotificationTimeService {
  static const int _fallbackHour = 19;

  static int _hourBucketCount(Map<String, dynamic> hourly, int hour) {
    final key = '$hour';
    final v = hourly[key] ?? hourly[hour.toString()];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// يقرأ `hourly` من [kActivityStatsGlobalPath] فقط.
  static Future<BestSendTimeResult> getBestSendTime(
    FirebaseFirestore db,
  ) async {
    try {
      final snap = await db.doc(kActivityStatsGlobalPath).get();
      if (!snap.exists) {
        return const BestSendTimeResult(
          bestHour: _fallbackHour,
          confidence: 0.38,
          sampleSize: 0,
        );
      }

      final m = snap.data()!;
      final raw = m['hourly'];
      if (raw is! Map) {
        return const BestSendTimeResult(
          bestHour: _fallbackHour,
          confidence: 0.4,
          sampleSize: 0,
        );
      }

      final hourly = Map<String, dynamic>.from(raw);
      var bestH = _fallbackHour;
      var maxC = -1;
      var total = 0;

      for (var i = 0; i < 24; i++) {
        final c = _hourBucketCount(hourly, i);
        total += c;
        if (c > maxC) {
          maxC = c;
          bestH = i;
        }
      }

      if (total <= 0 || maxC < 0) {
        return const BestSendTimeResult(
          bestHour: _fallbackHour,
          confidence: 0.4,
          sampleSize: 0,
        );
      }

      final peakRatio = maxC / total;
      var confidence = 0.45 + peakRatio * 0.48;
      if (total < 12) {
        confidence -= 0.12;
      } else if (total > 200) {
        confidence += 0.06;
      }
      confidence = confidence.clamp(0.35, 0.92);

      return BestSendTimeResult(
        bestHour: bestH,
        confidence: confidence,
        sampleSize: total,
      );
    } catch (_) {
      return const BestSendTimeResult(
        bestHour: _fallbackHour,
        confidence: 0.38,
        sampleSize: 0,
      );
    }
  }
}
