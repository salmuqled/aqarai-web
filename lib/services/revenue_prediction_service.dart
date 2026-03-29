/// Expected revenue from a push campaign using historical conversion economics.
abstract final class RevenuePredictionService {
  static const double fallbackConversionRate = 0.05;
  static const double fallbackAvgDealValue = 5000.0;

  /// Portfolio average deal value above this → small boost when variant mentions trending area.
  static const double highPortfolioAvgDealThreshold = 8000.0;

  static const double _boostAreaMention = 1.06;
  static const double _boostHighPortfolioExtra = 1.04;

  static int _int(dynamic v) {
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }

  static double _double(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? 0.0;
  }

  /// Rolling stats from [notification_logs] maps (newest-first is fine).
  static NotificationRevenueBaselines baselinesFromLogMaps(
    Iterable<Map<String, dynamic>> logMaps, {
    int maxLogs = 50,
  }) {
    final take = logMaps.take(maxLogs).toList();
    if (take.isEmpty) {
      return const NotificationRevenueBaselines(
        avgConversionRate: fallbackConversionRate,
        avgDealValue: fallbackAvgDealValue,
      );
    }

    var rateSum = 0.0;
    var rateN = 0;
    var dealValSum = 0.0;
    var dealValN = 0;

    for (final m in take) {
      final sent = _int(m['sentCount']);
      final conv = _int(m['conversionCount']);
      final cv = _double(m['conversionValue']);
      if (sent > 0) {
        rateSum += (conv / sent).clamp(0.0, 1.0);
        rateN++;
      }
      if (conv > 0 && cv > 0) {
        dealValSum += cv / conv;
        dealValN++;
      }
    }

    final avgRate = rateN > 0 ? rateSum / rateN : fallbackConversionRate;
    final avgDeal =
        dealValN > 0 ? dealValSum / dealValN : fallbackAvgDealValue;

    return NotificationRevenueBaselines(
      avgConversionRate: avgRate.clamp(0.0, 1.0),
      avgDealValue: avgDeal > 0 ? avgDeal : fallbackAvgDealValue,
    );
  }

  static PredictedRevenue predictRevenue({
    required double predictedCTR,
    required double conversionRate,
    required double avgDealValue,
    required int estimatedAudienceSize,
  }) {
    final audience = estimatedAudienceSize < 0 ? 0 : estimatedAudienceSize;
    final ctr = predictedCTR.isFinite ? predictedCTR.clamp(0.0, 1.0) : 0.0;
    final cr =
        conversionRate.isFinite ? conversionRate.clamp(0.0, 1.0) : 0.0;
    final adv = (!avgDealValue.isFinite || avgDealValue <= 0)
        ? fallbackAvgDealValue
        : avgDealValue;

    final expectedClicks = ctr * audience;
    final expectedConversions = expectedClicks * cr;
    final expectedRevenue = expectedConversions * adv;

    return PredictedRevenue(
      expectedClicks: expectedClicks,
      expectedConversions: expectedConversions,
      expectedRevenue:
          expectedRevenue.isFinite ? expectedRevenue : 0.0,
    );
  }

  /// Optional boost: variant text mentions [trendingAreaAr] and portfolio shows strong deal values.
  static double applyRevenueBoost({
    required double expectedRevenue,
    required String variantTitle,
    required String variantBody,
    String? trendingAreaAr,
    required double portfolioAvgDealValue,
  }) {
    if (!expectedRevenue.isFinite || expectedRevenue <= 0) {
      return expectedRevenue.isFinite ? expectedRevenue : 0.0;
    }
    final area = trendingAreaAr?.trim() ?? '';
    if (area.isEmpty) return expectedRevenue;

    final blob = '${variantTitle.trim()}\n${variantBody.trim()}';
    if (!blob.contains(area)) return expectedRevenue;

    var r = expectedRevenue * _boostAreaMention;
    if (portfolioAvgDealValue >= highPortfolioAvgDealThreshold) {
      r *= _boostHighPortfolioExtra;
    }
    return r.isFinite ? r : expectedRevenue;
  }

  static PredictedRevenue predictRevenueWithBoost({
    required double predictedCTR,
    required NotificationRevenueBaselines baselines,
    required int estimatedAudienceSize,
    required String variantTitle,
    required String variantBody,
    String? trendingAreaAr,
  }) {
    final base = predictRevenue(
      predictedCTR: predictedCTR,
      conversionRate: baselines.avgConversionRate,
      avgDealValue: baselines.avgDealValue,
      estimatedAudienceSize: estimatedAudienceSize,
    );
    final boosted = applyRevenueBoost(
      expectedRevenue: base.expectedRevenue,
      variantTitle: variantTitle,
      variantBody: variantBody,
      trendingAreaAr: trendingAreaAr,
      portfolioAvgDealValue: baselines.avgDealValue,
    );
    return PredictedRevenue(
      expectedClicks: base.expectedClicks,
      expectedConversions: base.expectedConversions,
      expectedRevenue: boosted,
    );
  }
}

class NotificationRevenueBaselines {
  const NotificationRevenueBaselines({
    required this.avgConversionRate,
    required this.avgDealValue,
  });

  final double avgConversionRate;
  final double avgDealValue;
}

class PredictedRevenue {
  const PredictedRevenue({
    required this.expectedClicks,
    required this.expectedConversions,
    required this.expectedRevenue,
  });

  final double expectedClicks;
  final double expectedConversions;
  final double expectedRevenue;
}
