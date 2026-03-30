import 'dart:math' as math;

import 'package:aqarai_app/models/caption_learning_weights.dart';
import 'package:aqarai_app/models/caption_variant_score.dart';
import 'package:aqarai_app/services/instagram_caption_service.dart';
import 'package:aqarai_app/utils/caption_factor_analyzer.dart';

/// Inputs for [generateCaptionVariants].
class CaptionVariantInput {
  const CaptionVariantInput({
    required this.area,
    required this.propertyType,
    required this.demandLevel,
    required this.isArabic,
    this.propertyId = '',
  });

  final String area;
  final String propertyType;
  final InstagramDemandLevel demandLevel;
  final bool isArabic;

  /// Listing id for `?id=` in caption link (optional).
  final String propertyId;
}

/// Builds 3 caption variants, scores them, returns sorted by score (best first).
abstract final class CaptionVariantService {
  CaptionVariantService._();

  /// Variant A (urgency), B (value), C (calm) + footer (CTA + trackable link + hashtags).
  ///
  /// [historicalCtrByVariant]: keys `A`/`B`/`C`, values 0…1+ from [CaptionPerformanceService].
  /// [learningWeights]: from [CaptionLearningService.getWeights] or [CaptionLearningWeights.defaults].
  static List<CaptionVariantScore> generateCaptionVariants(
    CaptionVariantInput data, {
    Map<String, double> historicalCtrByVariant = const {},
    CaptionLearningWeights learningWeights = CaptionLearningWeights.defaults,
  }) {
    final a = data.area.trim().isEmpty
        ? (data.isArabic ? 'الكويت' : 'Kuwait')
        : data.area.trim();
    final t = data.propertyType.trim().isEmpty
        ? (data.isArabic ? 'عقار' : 'property')
        : data.propertyType.trim();
    final pid = data.propertyId.trim();

    double ctrBonus(String id) =>
        0.5 *
        (historicalCtrByVariant[id] ??
            historicalCtrByVariant[id.toUpperCase()] ??
            0);

    final footerA = InstagramCaptionService.postFooterSuffix(
      area: a,
      propertyType: t,
      demandLevel: data.demandLevel,
      isArabic: data.isArabic,
      propertyId: pid,
      captionVariantId: 'A',
    );
    final footerB = InstagramCaptionService.postFooterSuffix(
      area: a,
      propertyType: t,
      demandLevel: data.demandLevel,
      isArabic: data.isArabic,
      propertyId: pid,
      captionVariantId: 'B',
    );
    final footerC = InstagramCaptionService.postFooterSuffix(
      area: a,
      propertyType: t,
      demandLevel: data.demandLevel,
      isArabic: data.isArabic,
      propertyId: pid,
      captionVariantId: 'C',
    );

    final bodyA = data.isArabic
        ? '🔥 فرصة قوية في $a\n📊 الطلب مرتفع'
        : '🔥 Strong opportunity in $a\n📊 Demand is high';
    final bodyB = data.isArabic
        ? '🏠 أفضل أسعار $t في $a\n✨ فرص مميزة'
        : '🏠 Best $t prices in $a\n✨ Great opportunities';
    final bodyC = data.isArabic
        ? '📊 سوق $a يشهد حركة مستقرة\n🏠 خيارات متعددة'
        : '📊 The $a market is moving steadily\n🏠 Multiple options';

    final capA = '$bodyA$footerA';
    final capB = '$bodyB$footerB';
    final capC = '$bodyC$footerC';

    final minLen =
        [capA.length, capB.length, capC.length].reduce(math.min);

    double learnedScore(
      String caption, {
      required bool isShortest,
    }) {
      var s = 0.0;
      if (CaptionFactorAnalyzer.hasEmoji(caption)) {
        s += learningWeights.emoji;
      }
      if (CaptionFactorAnalyzer.hasArea(caption, a)) {
        s += learningWeights.area;
      }
      if (CaptionFactorAnalyzer.hasUrgency(caption)) {
        s += learningWeights.urgency;
      }
      if (isShortest) {
        s += learningWeights.shortText;
      }
      return s;
    }

    final raw = [
      CaptionVariantScore(
        variantId: 'A',
        caption: capA,
        score: learnedScore(capA, isShortest: capA.length == minLen) +
            ctrBonus('A'),
      ),
      CaptionVariantScore(
        variantId: 'B',
        caption: capB,
        score: learnedScore(capB, isShortest: capB.length == minLen) +
            ctrBonus('B'),
      ),
      CaptionVariantScore(
        variantId: 'C',
        caption: capC,
        score: learnedScore(capC, isShortest: capC.length == minLen) +
            ctrBonus('C'),
      ),
    ];

    raw.sort((x, y) {
      final c = y.score.compareTo(x.score);
      if (c != 0) return c;
      return x.variantId.compareTo(y.variantId);
    });

    return raw;
  }
}
