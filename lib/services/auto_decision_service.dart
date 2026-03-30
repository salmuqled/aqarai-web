import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auto_decision.dart';
import 'package:aqarai_app/models/auto_decision_trust.dart';
import 'package:aqarai_app/models/caption_variant_score.dart';
import 'package:aqarai_app/services/caption_learning_service.dart';
import 'package:aqarai_app/services/caption_performance_service.dart';
import 'package:aqarai_app/services/caption_variant_service.dart';
import 'package:aqarai_app/services/instagram_caption_service.dart';
import 'package:aqarai_app/config/auto_mode_config.dart';
import 'package:aqarai_app/services/decision_tracking_service.dart';
import 'package:aqarai_app/services/hybrid_marketing_settings_service.dart';
import 'package:aqarai_app/services/notification_audience_service.dart';
import 'package:aqarai_app/services/notification_time_service.dart';
import 'package:aqarai_app/utils/caption_factor_analyzer.dart';

/// Combines time, audience, caption variants, CTR, and learning into one recommendation.
abstract final class AutoDecisionService {
  AutoDecisionService._();

  static InstagramDemandLevel _demand(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'high':
        return InstagramDemandLevel.high;
      case 'low':
        return InstagramDemandLevel.low;
      default:
        return InstagramDemandLevel.medium;
    }
  }

  static DateTime _nextOccurrenceOfHourLocal(int hour) {
    final h = hour.clamp(0, 23);
    final now = DateTime.now();
    var t = DateTime(now.year, now.month, now.day, h, 0);
    if (!t.isAfter(now)) {
      t = t.add(const Duration(days: 1));
    }
    return t;
  }

  static String _truncateBody(String s, {int max = 220}) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= max) return t;
    return '${t.substring(0, max - 1)}…';
  }

  static Future<double> _learningConfidence(FirebaseFirestore db) async {
    try {
      final snap = await db.collection('caption_learning').get();
      if (snap.docs.isEmpty) return 0.42;
      var sum = 0.0;
      for (final d in snap.docs) {
        final s = d.data()['samples'];
        final n = s is num ? s.toDouble() : 0.0;
        sum += (n / 180).clamp(0.0, 1.0);
      }
      return (sum / snap.docs.length).clamp(0.2, 0.92);
    } catch (_) {
      return 0.42;
    }
  }

  static String _buildReason({
    required bool isArabic,
    required CaptionVariantScore best,
    required String area,
    required double histCtr,
    required String segment,
  }) {
    final parts = <String>[];
    if (CaptionFactorAnalyzer.hasUrgency(best.caption)) {
      parts.add(isArabic ? 'يحتوي على 🔥' : 'Uses 🔥 urgency');
    }
    if (CaptionFactorAnalyzer.hasArea(best.caption, area)) {
      parts.add(isArabic ? 'ذكر المنطقة' : 'Mentions area');
    }
    if (histCtr >= 0.12) {
      parts.add(isArabic ? 'أداء سابق قوي' : 'Strong past CTR');
    } else if (histCtr > 0) {
      parts.add(isArabic ? 'بيانات نقر سابقة' : 'Some click history');
    }
    if (segment == 'active') {
      parts.add(isArabic ? 'جمهور نشط الآن' : 'Active users segment');
    } else if (segment == 'warm') {
      parts.add(isArabic ? 'جمهور دافئ' : 'Warm audience');
    }
    if (parts.isEmpty) {
      return isArabic
          ? 'توصية افتراضية من أوزان التعلّم والبيانات المتاحة.'
          : 'Default blend from learning weights and available data.';
    }
    return parts.join(isArabic ? ' + ' : ' · ');
  }

  static String decisionLevelForConfidence(
    double confidence, {
    required double autoThreshold,
    required double reviewThreshold,
  }) {
    if (confidence >= autoThreshold) return 'auto';
    if (confidence >= reviewThreshold) return 'review';
    return 'manual';
  }

  /// All must pass for unattended auto; else caller should downgrade to `review`.
  static bool passesStrictAutoEligibility({
    required double confidence,
    required double expectedCtr,
    required AutoDecisionTrust trust,
    required double autoThreshold,
  }) {
    return confidence >= autoThreshold &&
        expectedCtr >= AutoModeConfig.strictAutoMinExpectedCtr &&
        trust.captionTrust >= AutoModeConfig.strictAutoMinCaptionTrust &&
        trust.timeTrust >= AutoModeConfig.strictAutoMinTimeTrust &&
        trust.audienceTrust >= AutoModeConfig.strictAutoMinAudienceTrust;
  }

  /// Picks caption variant + time + audience; **does not** send anything.
  static Future<AutoDecision> generateDecision({
    required String area,
    required String propertyType,
    required int dealsCount,
    required String demandLevel,
    required bool isArabic,
    String propertyIdForTracking = '',
  }) async {
    final db = FirebaseFirestore.instance;
    final hybrid = await HybridMarketingSettingsService.load();
    final autoT = hybrid.autoThreshold;
    final reviewT = hybrid.reviewThreshold;

    try {
      final gate = await DecisionTrackingService.getAutoMarketingGateState();
      final trust = gate.trust;
      final time = await NotificationTimeService.getBestSendTime(db);
      final audience = await NotificationAudienceService.getBestAudience(db);
      final ctrMap =
          await CaptionPerformanceService().getHistoricalCtrByVariant();
      final weights = await CaptionLearningService.getWeights();
      final perf = await CaptionPerformanceService().getPerformance();

      final demand = _demand(demandLevel);
      final variants = CaptionVariantService.generateCaptionVariants(
        CaptionVariantInput(
          area: area,
          propertyType: propertyType,
          demandLevel: demand,
          isArabic: isArabic,
          propertyId: propertyIdForTracking,
        ),
        historicalCtrByVariant: ctrMap,
        learningWeights: weights,
      );

      if (variants.isEmpty) {
        return _fallback(
          area: area,
          propertyType: propertyType,
          isArabic: isArabic,
          demand: demand,
          autoThreshold: autoT,
          reviewThreshold: reviewT,
        );
      }

      double learnedOnly(CaptionVariantScore v) {
        final id = v.variantId.toUpperCase();
        final ctr = ctrMap[id] ?? 0.0;
        return v.score - 0.5 * ctr;
      }

      final ls = variants.map(learnedOnly).toList();
      final minL = ls.reduce(math.min);
      final maxL = ls.reduce(math.max);
      final span = (maxL - minL).abs() < 1e-9 ? 1.0 : (maxL - minL);

      double normLearned(CaptionVariantScore v) {
        return ((learnedOnly(v) - minL) / span).clamp(0.0, 1.0);
      }

      final audMult =
          NotificationAudienceService.ctrMultiplier(audience.recommendedSegment);

      CaptionVariantScore? pick;
      var bestFs = -1.0;
      for (final v in variants) {
        final id = v.variantId.toUpperCase();
        final hist = (ctrMap[id] ?? 0.0).clamp(0.0, 1.0);
        final captionScore = normLearned(v);
        final fs = captionScore * trust.captionTrust * 0.4 +
            hist * 0.4 +
            audMult * trust.audienceTrust * 0.1 +
            time.confidence * trust.timeTrust * 0.1;
        if (fs > bestFs) {
          bestFs = fs;
          pick = v;
        }
      }
      pick ??= variants.first;

      final id = pick.variantId.toUpperCase();
      final histCtr = (ctrMap[id] ?? 0.0).clamp(0.0, 1.0);
      final expectedCtr = (histCtr * audMult).clamp(0.0, 1.0);

      final learnC = await _learningConfidence(db);
      final totalImp = perf.fold<int>(0, (a, b) => a + b.impressions);
      final totalClk = perf.fold<int>(0, (a, b) => a + b.clicks);
      final dataSize =
          ((totalImp + totalClk) / 72).clamp(0.12, 1.0).toDouble();

      final baseConfidence = (time.confidence + learnC + dataSize) / 3;
      final confidence = (baseConfidence * trust.averageTrust).clamp(0.0, 1.0);

      final scheduleAt = _nextOccurrenceOfHourLocal(time.bestHour);
      final title = isArabic
          ? 'عروض في ${area.trim().isEmpty ? 'الكويت' : area.trim()}'
          : 'Listings in ${area.trim().isEmpty ? 'Kuwait' : area.trim()}';
      final body = _truncateBody(pick.caption);

      final reason = _buildReason(
        isArabic: isArabic,
        best: pick,
        area: area,
        histCtr: histCtr,
        segment: audience.recommendedSegment,
      );

      var decisionLevel = decisionLevelForConfidence(
        confidence,
        autoThreshold: autoT,
        reviewThreshold: reviewT,
      );
      if (decisionLevel == 'auto') {
        if (gate.autoShieldEnabled ||
            !passesStrictAutoEligibility(
              confidence: confidence,
              expectedCtr: expectedCtr,
              trust: trust,
              autoThreshold: autoT,
            )) {
          decisionLevel = 'review';
        }
      }

      return AutoDecision(
        bestHour: time.bestHour,
        audienceSegment: audience.recommendedSegment,
        captionId: id,
        captionText: pick.caption,
        expectedCtr: expectedCtr,
        confidence: confidence,
        reason: reason,
        suggestedScheduleAt: scheduleAt,
        notificationTitle: title,
        notificationBody: body,
        decisionLevel: decisionLevel,
      );
    } catch (_) {
      return _fallback(
        area: area,
        propertyType: propertyType,
        isArabic: isArabic,
        demand: _demand(demandLevel),
        autoThreshold: autoT,
        reviewThreshold: reviewT,
      );
    }
  }

  static AutoDecision _fallback({
    required String area,
    required String propertyType,
    required bool isArabic,
    required InstagramDemandLevel demand,
    double? autoThreshold,
    double? reviewThreshold,
  }) {
    final autoT = autoThreshold ?? AutoModeConfig.autoThreshold;
    final reviewT = reviewThreshold ?? AutoModeConfig.reviewThreshold;
    final cap = InstagramCaptionService.generateInstagramCaption(
      area: area,
      propertyType: propertyType,
      demandLevel: demand,
      recentDealsCount: 0,
      isArabic: isArabic,
    );
    final scheduleAt = _nextOccurrenceOfHourLocal(19);
    final title = isArabic ? 'عروض عقارية' : 'Property updates';
    final body = _truncateBody(cap);
    const conf = 0.35;
    return AutoDecision(
      bestHour: 19,
      audienceSegment: 'active',
      captionId: 'A',
      captionText: cap,
      expectedCtr: 0.12,
      confidence: conf,
      reason: isArabic
          ? 'بيانات غير كافية — توصية آمنة افتراضية.'
          : 'Limited data — safe default recommendation.',
      suggestedScheduleAt: scheduleAt,
      notificationTitle: title,
      notificationBody: body,
      decisionLevel: decisionLevelForConfidence(
        conf,
        autoThreshold: autoT,
        reviewThreshold: reviewT,
      ),
    );
  }
}
