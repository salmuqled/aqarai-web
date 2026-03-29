import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/services/notification_audience_service.dart';
import 'package:aqarai_app/services/notification_decision_service.dart';
import 'package:aqarai_app/services/notification_time_service.dart';
import 'package:aqarai_app/services/revenue_prediction_service.dart';

/// دمج وقت الإرسال + الشريحة + تقدير العائد (قرار إعلامي؛ الإرسال يبقى بموافقة الأدمن).
class NotificationStrategy {
  const NotificationStrategy({
    required this.bestHour,
    required this.timeConfidence,
    required this.bestAudience,
    required this.audienceEstimatedSize,
    required this.expectedRevenue,
    required this.confidence,
  });

  final int bestHour;
  final double timeConfidence;

  /// `active` | `warm` | `cold` | `all`
  final String bestAudience;
  final int audienceEstimatedSize;
  final double expectedRevenue;
  final double confidence;
}

abstract final class NotificationStrategyService {
  /// يحسب الاستراتيجية من تحليل النشاط + قرار النسخة + اقتصاديات السجل.
  static Future<NotificationStrategy> build({
    required FirebaseFirestore db,
    required NotificationDecision decision,
    required NotificationRevenueBaselines baselines,
    required int estimatedAudienceSize,
  }) async {
    final time = await NotificationTimeService.getBestSendTime(db);
    final aud = await NotificationAudienceService.getBestAudience(db);

    final mult =
        NotificationAudienceService.ctrMultiplier(aud.recommendedSegment);
    final adjCtr = (decision.predictedCTR * mult).clamp(0.0, 1.0);

    final audienceForRev = aud.recommendedSegment == 'all' ||
            aud.recommendedSize <= 0
        ? estimatedAudienceSize
        : aud.recommendedSize;

    final rev = RevenuePredictionService.predictRevenue(
      predictedCTR: adjCtr,
      conversionRate: baselines.avgConversionRate,
      avgDealValue: baselines.avgDealValue,
      estimatedAudienceSize: audienceForRev,
    );

    final conf = (time.confidence + aud.confidence + decision.confidence) / 3.0;

    return NotificationStrategy(
      bestHour: time.bestHour,
      timeConfidence: time.confidence,
      bestAudience: aud.recommendedSegment,
      audienceEstimatedSize:
          aud.recommendedSize > 0 ? aud.recommendedSize : estimatedAudienceSize,
      expectedRevenue: rev.expectedRevenue,
      confidence: conf.clamp(0.5, 0.92),
    );
  }

  static DateTime nextLocalSendAt(int hour0to23) {
    final now = DateTime.now();
    var t = DateTime(now.year, now.month, now.day, hour0to23.clamp(0, 23), 0);
    if (!t.isAfter(now)) {
      t = t.add(const Duration(days: 1));
    }
    return t;
  }
}
