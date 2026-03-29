import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/models/admin_recommendation.dart';
import 'package:aqarai_app/models/personalized_trending_payload.dart';
import 'package:aqarai_app/services/admin_action_service.dart';
import 'package:aqarai_app/services/admin_intelligence_service.dart';
import 'package:aqarai_app/services/smart_notification_service.dart';
import 'package:aqarai_app/utils/admin_decision_trends.dart';
import 'package:aqarai_app/widgets/admin_notification_preview_dialog.dart';

/// Trend-aware recommendations from the same streamed samples as operational intelligence.
abstract final class AdminRecommendationsService {
  static String _pct1(double x) => '${(x * 100).toStringAsFixed(1)}%';

  /// Uses [day] (today vs yesterday sample) plus [totalDealsGlobal] to avoid noisy rules when there is no history.
  static List<AdminRecommendation> generateRecommendations({
    required DaySampleMetrics day,
    required int totalDealsGlobal,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> viewDocs,
    required BuildContext context,
    required bool isAr,
  }) {
    final out = <AdminRecommendation>[];

    final aiToday = day.todayAiShare;
    final aiYesterday = day.yesterdayAiShare;
    final hasAiBaseline = day.yesterdayDeals > 0;
    final aiDelta =
        hasAiBaseline ? calculateChange(aiToday, aiYesterday) : null;
    final aiTrend =
        aiDelta != null ? getTrend(aiDelta) : AdminRecommendationTrend.stable;

    final convToday = day.conversionTodaySample;
    final convYesterday = day.conversionYesterdaySample;
    final hasConvBaseline =
        day.yesterdayDeals > 0 && day.yesterdayViews > 0;
    final convDelta = hasConvBaseline
        ? calculateChange(convToday, convYesterday)
        : null;
    final convTrend = convDelta != null
        ? getTrend(convDelta)
        : AdminRecommendationTrend.stable;

    final canUseAiRules = totalDealsGlobal > 0 && day.todayDeals > 0;
    final canUseConvRules = totalDealsGlobal > 0 &&
        day.todayDeals > 0 &&
        day.todayViews > 0;

    if (canUseAiRules && aiToday < 0.2) {
      final desc = isAr
          ? 'حصّة صفقات اليوم من الذكاء الاصطناعي دون الهدف. حسّن المطالبات وجودة المطابقة.'
          : 'Today’s AI deal share is below target. Improve prompts and matching quality.';
      out.add(
        _rec(
          context: context,
          isAr: isAr,
          title: isAr
              ? '🚨 AI منخفض (${_pct1(aiToday)})'
              : '🚨 Low AI share (${_pct1(aiToday)})',
          description: desc,
          actionLabel: isAr ? 'تحسين الآن' : 'Improve now',
          type: AdminRecommendationType.warning,
          confidence: 0.85,
          priority: AdminRecommendationPriority.high,
          impact: AdminRecommendationImpact.high,
          value: aiToday,
          change: aiDelta,
          trend: aiTrend,
          canSendNotification: false,
          snackbarHint: isAr
              ? 'راجع مطالبات المساعد، تطابق العقارات مع الاستعلامات، وعرض قصص نجاح الذكاء الاصطناعي للوكلاء.'
              : 'Review assistant prompts, property matching, and surface AI success stories to agents.',
        ),
      );
    } else if (canUseAiRules && aiToday > 0.4) {
      final desc = isAr
          ? 'أداء قوي للذكاء الاصطناعي اليوم. زِد نقاط الدخول والظهور.'
          : 'Strong AI performance today. Scale entry points and visibility.';
      out.add(
        _rec(
          context: context,
          isAr: isAr,
          title: isAr
              ? '🤖 AI قوي (${_pct1(aiToday)})'
              : '🤖 Strong AI share (${_pct1(aiToday)})',
          description: desc,
          actionLabel: isAr ? 'توسيع الظهور' : 'Scale exposure',
          type: AdminRecommendationType.success,
          confidence: 0.78,
          priority: AdminRecommendationPriority.medium,
          impact: AdminRecommendationImpact.high,
          value: aiToday,
          change: aiDelta,
          trend: aiTrend,
          canSendNotification: false,
          snackbarHint: isAr
              ? 'أضف مسارات دخول للذكاء الاصطناعي في الرئيسية والإعلانات، واختبر التمييز للصفقات المنشأة من المحادثة.'
              : 'Add AI entry points on home and listings, and test featured placement for AI-originated deals.',
        ),
      );
    }

    if (canUseConvRules && convToday < 0.05) {
      final desc = isAr
          ? 'التحويل في عيّنة اليوم منخفض (صفقات ÷ مشاهدات). ركّز على جودة الإعلان والصور والسعر.'
          : 'Today’s sample funnel conversion is low (deals ÷ views). Focus on listing quality, photos, and pricing.';
      out.add(
        _rec(
          context: context,
          isAr: isAr,
          title: isAr
              ? '📉 تحويل منخفض (${_pct1(convToday)})'
              : '📉 Low conversion (${_pct1(convToday)})',
          description: desc,
          actionLabel: isAr ? 'مراجعة الإعلانات' : 'Review listings',
          type: AdminRecommendationType.danger,
          confidence: 0.85,
          priority: AdminRecommendationPriority.high,
          impact: AdminRecommendationImpact.high,
          value: convToday,
          change: convDelta,
          trend: convTrend,
          canSendNotification: false,
          snackbarHint: isAr
              ? 'حسّن الصور والوصف والسعر وزمن الاستجابة للإعلانات ذات المشاهدات العالية وقلة الصفقات.'
              : 'Improve photos, pricing, descriptions, and response time on high-view, low-deal listings.',
        ),
      );
    }

    if (day.todayDeals == 0) {
      final bundle = SmartNotificationService.generateFromData(
        deals: dealDocs,
        views: viewDocs,
        isAr: isAr,
      );
      final primary = bundle.broadcastVariants.isNotEmpty
          ? bundle.broadcastVariants.first
          : const SmartNotificationSuggestion(title: '', body: '');
      final nt = primary.title.trim();
      final nb = primary.body.trim();
      final payload = PersonalizedTrendingPayload(
        trendingAreaAr: bundle.trendingAreaAr,
        trendingAreaEn: bundle.trendingAreaEn,
        dominantPropertyKind: bundle.dominantPropertyKind,
      );

      out.add(
        _rec(
          context: context,
          isAr: isAr,
          title: isAr ? '🚨 لا توجد صفقات اليوم' : '🚨 No deals today',
          description: isAr
              ? 'لا صفقات في عيّنة اليوم — فكّر بحملة تسويقية أو متابعة العملاء.'
              : 'No deals in today’s sample — consider marketing or follow-ups.',
          actionLabel: isAr ? 'إرسال عام' : 'Broadcast',
          type: AdminRecommendationType.danger,
          confidence: 0.72,
          priority: AdminRecommendationPriority.high,
          impact: AdminRecommendationImpact.high,
          value: null,
          change: null,
          trend: AdminRecommendationTrend.stable,
          canSendNotification: true,
          notificationTitle: nt,
          notificationBody: nb,
          smartBundle: bundle,
          personalizedPayload: payload,
          snackbarHint: null,
        ),
      );
    }

    if (out.isEmpty) {
      out.add(
        _rec(
          context: context,
          isAr: isAr,
          title: isAr
              ? 'أداء مستقر'
              : 'System performance is stable',
          description: isAr
              ? 'لا تنبيهات قاعدة القواعد حالياً — تابع المؤشرات بانتظام.'
              : 'No rule-based alerts right now — metrics look steady.',
          actionLabel: isAr ? 'حسناً' : 'OK',
          type: AdminRecommendationType.success,
          confidence: 0.55,
          priority: AdminRecommendationPriority.low,
          impact: AdminRecommendationImpact.low,
          value: null,
          change: null,
          trend: AdminRecommendationTrend.stable,
          canSendNotification: false,
          snackbarHint: isAr
              ? 'المؤشرات ضمن نطاق عادي. استمر بمراجعة المصادر وجودة الإعلانات.'
              : 'Metrics are within a normal band. Keep monitoring sources and listing quality.',
        ),
      );
    }

    return out;
  }

  static AdminRecommendation _rec({
    required BuildContext context,
    required bool isAr,
    required String title,
    required String description,
    required String actionLabel,
    required String type,
    required double confidence,
    required String priority,
    required String impact,
    required double? value,
    required double? change,
    required String trend,
    required bool canSendNotification,
    String? notificationTitle,
    String? notificationBody,
    String? snackbarHint,
    SmartNotificationBundle? smartBundle,
    PersonalizedTrendingPayload? personalizedPayload,
  }) {
    final c = confidence.clamp(0.0, 1.0);
    final nt = notificationTitle?.trim() ?? '';
    final nb = notificationBody?.trim() ?? '';

    void openPreview(NotificationSendMode initialMode) {
      if (!context.mounted) return;
      if (smartBundle != null && personalizedPayload != null) {
        openSmartNotificationPreview(
          context: context,
          initialMode: initialMode,
          broadcastVariants: smartBundle.broadcastVariants,
          samplePersonalizedTitle: smartBundle.personalizedSampleTitle,
          samplePersonalizedBody: smartBundle.personalizedSampleBody,
          personalizedPayload: personalizedPayload,
          isAr: isAr,
        );
        return;
      }
      if (nt.isEmpty || nb.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              isAr ? 'نص الإشعار غير جاهز.' : 'Notification text is not ready.',
            ),
          ),
        );
        return;
      }
      showNotificationPreviewDialog(
        context: context,
        initialMode: NotificationSendMode.broadcast,
        broadcastTitle: nt,
        broadcastBody: nb,
        samplePersonalizedTitle: '',
        samplePersonalizedBody: '',
        isAr: isAr,
        showPersonalizedOption: false,
        onConfirm: (mode, editedTitle, editedBody,
            {abBroadcastVariants,
            sendPredictedBestOnly,
            sendPredictedMeta,
            abPredictionByCanonical,
            trendingAreaArForAb,
            scheduledSendAt,
            audienceSegment}) async {
          if (!context.mounted) return;
          if (sendPredictedBestOnly != null) {
            if (scheduledSendAt != null) {
              await AdminActionService.queueScheduledNotification(
                context: context,
                title: sendPredictedBestOnly.title,
                body: sendPredictedBestOnly.body,
                scheduledAt: scheduledSendAt,
                isAr: isAr,
                source: 'admin_recommendation',
                predictionLog: sendPredictedMeta,
                trendingAreaAr: trendingAreaArForAb,
                audienceSegment: audienceSegment,
              );
              return;
            }
            await AdminActionService.sendNotification(
              context: context,
              title: sendPredictedBestOnly.title,
              body: sendPredictedBestOnly.body,
              isAr: isAr,
              source: 'admin_recommendation',
              predictionLog: sendPredictedMeta,
              trendingAreaAr: trendingAreaArForAb,
              audienceSegment: audienceSegment,
            );
            return;
          }
          await AdminActionService.sendNotification(
            context: context,
            title: editedTitle,
            body: editedBody,
            isAr: isAr,
            source: 'admin_recommendation',
          );
        },
      );
    }

    return AdminRecommendation(
      title: title,
      description: description,
      actionLabel: actionLabel,
      type: type,
      confidence: c,
      priority: priority,
      impact: impact,
      value: value,
      change: change,
      trend: trend,
      canSendNotification: canSendNotification,
      notificationTitle: canSendNotification ? nt : null,
      notificationBody: canSendNotification ? nb : null,
      onAction: () {
        if (!context.mounted) return;
        if (canSendNotification) {
          openPreview(NotificationSendMode.broadcast);
        } else {
          final hint = snackbarHint;
          if (hint == null || hint.isEmpty) return;
          final messenger = ScaffoldMessenger.maybeOf(context);
          if (messenger == null) return;
          messenger.showSnackBar(
            SnackBar(
              content: Text(hint),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      onPersonalizedAction: canSendNotification &&
              smartBundle != null &&
              personalizedPayload != null
          ? () {
              if (!context.mounted) return;
              openPreview(NotificationSendMode.personalized);
            }
          : null,
    );
  }
}
