import 'dart:math' as math;

import 'package:aqarai_app/services/notification_prediction_service.dart';
import 'package:aqarai_app/services/revenue_prediction_service.dart';

/// نتيجة اختيار تلقائي لنسخة الإشعار (لا إرسال بدون موافقة الأدمن).
class NotificationDecision {
  const NotificationDecision({
    required this.selectedText,
    required this.expectedRevenue,
    required this.predictedCTR,
    required this.confidence,
    required this.reason,
  });

  /// نص [PredictedNotification.text] (كانوني) للنسخة المختارة.
  final String selectedText;
  final double expectedRevenue;
  final double predictedCTR;

  /// بين 0.7 و 0.9 حسب حجم العيّنة وتباعد العائدات وثبات التنبؤ.
  final double confidence;
  final String reason;
}

abstract final class NotificationDecisionService {
  /// يختار النسخة ذات أعلى [PredictedRevenue.expectedRevenue] (مع تعادل CTR).
  static NotificationDecision? chooseBestVariant({
    required List<PredictedNotification> variants,
    required List<PredictedRevenue> revenues,
    required bool isAr,
    int pastLogsSampleSize = 0,
    String? trendingAreaAr,
    List<String>? variantTitles,
    List<String>? variantBodies,
  }) {
    if (variants.isEmpty || variants.length != revenues.length) {
      return null;
    }

    var bestI = 0;
    var bestRev = revenues[0].expectedRevenue;
    for (var i = 1; i < variants.length; i++) {
      final r = revenues[i].expectedRevenue;
      final better = r > bestRev ||
          (r == bestRev &&
              variants[i].predictedCTR > variants[bestI].predictedCTR);
      if (better) {
        bestRev = r;
        bestI = i;
      }
    }

    final winner = variants[bestI];
    final winRev = revenues[bestI];

    final revAmounts = revenues.map((e) => e.expectedRevenue).toList();
    final maxR = revAmounts.reduce(math.max);
    final minR = revAmounts.reduce(math.min);
    final spread = maxR > 1e-6 ? (maxR - minR) / maxR : 0.0;

    final ctrs = variants.map((v) => v.predictedCTR).toList();
    final ctrMean =
        ctrs.fold<double>(0, (a, b) => a + b) / ctrs.length.clamp(1, 999);
    var ctrVarSum = 0.0;
    for (final c in ctrs) {
      final d = c - ctrMean;
      ctrVarSum += d * d;
    }
    final ctrVariance =
        ctrs.length > 1 ? ctrVarSum / ctrs.length : 0.0;
    final ctrCv =
        ctrMean > 1e-6 ? math.sqrt(ctrVariance) / ctrMean : 0.0;

    var confidence = 0.72;
    if (pastLogsSampleSize >= 150) {
      confidence += 0.06;
    } else if (pastLogsSampleSize >= 80) {
      confidence += 0.04;
    } else if (pastLogsSampleSize >= 30) {
      confidence += 0.02;
    } else if (pastLogsSampleSize < 8) {
      confidence -= 0.04;
    }

    if (spread > 0.15) {
      confidence += 0.06;
    } else if (spread > 0.08) {
      confidence += 0.03;
    } else if (spread < 0.02) {
      confidence -= 0.05;
    }

    if (ctrCv < 0.08) {
      confidence -= 0.03;
    } else if (ctrCv > 0.2) {
      confidence += 0.02;
    }

    confidence = confidence.clamp(0.7, 0.9);

    final secondBest = _secondBestRevenue(revAmounts, bestI);
    final revenueLead = maxR > 1e-6 ? (maxR - secondBest) / maxR : 0.0;

    final wt = (variantTitles != null && bestI < variantTitles.length)
        ? variantTitles[bestI]
        : '';
    final wb = (variantBodies != null && bestI < variantBodies.length)
        ? variantBodies[bestI]
        : '';
    final area = trendingAreaAr?.trim() ?? '';
    final blob = '${wt.trim()} ${wb.trim()}';
    final mentionsArea = area.isNotEmpty && blob.contains(area);

    final reason = _buildReason(
      isAr: isAr,
      mentionsArea: mentionsArea,
      spread: spread,
      revenueLead: revenueLead,
      pastLogsSampleSize: pastLogsSampleSize,
      highRevenueWinner: bestRev >= maxR - 1e-6,
    );

    return NotificationDecision(
      selectedText: winner.text,
      expectedRevenue: winRev.expectedRevenue,
      predictedCTR: winner.predictedCTR,
      confidence: confidence,
      reason: reason,
    );
  }

  static double _secondBestRevenue(List<double> revs, int bestI) {
    var second = 0.0;
    var seen = false;
    for (var i = 0; i < revs.length; i++) {
      if (i == bestI) continue;
      final r = revs[i];
      if (!seen || r > second) {
        second = r;
        seen = true;
      }
    }
    return second;
  }

  static String _buildReason({
    required bool isAr,
    required bool mentionsArea,
    required double spread,
    required double revenueLead,
    required int pastLogsSampleSize,
    required bool highRevenueWinner,
  }) {
    final parts = <String>[];

    if (isAr) {
      if (highRevenueWinner && revenueLead > 0.12) {
        parts.add('تنبؤ عائد أعلى بوضوح مقارنة بالنسخ الأخرى.');
      } else if (spread > 0.1) {
        parts.add('فارق جيد في العائد المتوقع بين النسخ.');
      }
      if (mentionsArea) {
        parts.add('النص يذكر منطقة ذات اهتمام حالي مع أداء تاريخي قوي.');
      }
      if (pastLogsSampleSize >= 50) {
        parts.add('سجل إشعارات كافٍ لدعم تقدير التحويل.');
      } else if (pastLogsSampleSize >= 15) {
        parts.add('يعتمد التقدير على عيّنة سجلات محدودة.');
      }
      if (parts.isEmpty) {
        parts.add('أفضل خيار حسب نموذج العائد والنقرات الحالي.');
      }
    } else {
      if (highRevenueWinner && revenueLead > 0.12) {
        parts.add('Clear revenue lead vs other variants.');
      } else if (spread > 0.1) {
        parts.add('Meaningful spread in expected revenue across variants.');
      }
      if (mentionsArea) {
        parts.add(
          'High demand in this area with messaging aligned to trending interest.',
        );
      }
      if (pastLogsSampleSize >= 50) {
        parts.add('Enough notification history to support conversion estimates.');
      } else if (pastLogsSampleSize >= 15) {
        parts.add('Estimates lean on a smaller log sample.');
      }
      if (parts.isEmpty) {
        parts.add('Best fit under the current revenue + CTR model.');
      }
    }

    return parts.take(2).join(' ');
  }
}
