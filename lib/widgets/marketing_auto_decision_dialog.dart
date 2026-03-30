import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/config/auto_mode_config.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auto_decision.dart';
import 'package:aqarai_app/models/auto_marketing_gate_state.dart';
import 'package:aqarai_app/models/notification_learning_factors.dart';
import 'package:aqarai_app/services/admin_action_service.dart';
import 'package:aqarai_app/services/auto_decision_service.dart';
import 'package:aqarai_app/services/decision_tracking_service.dart';
import 'package:aqarai_app/services/hybrid_marketing_settings_service.dart';
import 'package:aqarai_app/utils/caption_factor_analyzer.dart';
import 'package:aqarai_app/widgets/admin_notification_preview_dialog.dart';

/// After Instagram carousel: smart push recommendation (hybrid auto / review / manual).
Future<void> showMarketingAutoDecisionDialog({
  required BuildContext context,
  required String area,
  required String propertyType,
  required int dealsCount,
  required String demandLevel,
  required bool isArabic,
  required String propertyIdForTracking,
}) async {
  if (!context.mounted) return;

  AutoDecision decision;
  try {
    decision = await AutoDecisionService.generateDecision(
      area: area,
      propertyType: propertyType,
      dealsCount: dealsCount,
      demandLevel: demandLevel,
      isArabic: isArabic,
      propertyIdForTracking: propertyIdForTracking,
    );
  } catch (_) {
    return;
  }

  if (!context.mounted) return;

  final hybrid = await HybridMarketingSettingsService.load();
  if (!context.mounted) return;

  final gate = await DecisionTrackingService.getAutoMarketingGateState();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => _MarketingAutoDecisionContent(
      parentContext: context,
      decision: decision,
      area: area,
      isAr: isArabic,
      hybridSettings: hybrid,
      gateState: gate,
    ),
  );
}

class _MarketingAutoDecisionContent extends StatefulWidget {
  const _MarketingAutoDecisionContent({
    required this.parentContext,
    required this.decision,
    required this.area,
    required this.isAr,
    required this.hybridSettings,
    required this.gateState,
  });

  final BuildContext parentContext;
  final AutoDecision decision;
  final String area;
  final bool isAr;
  final HybridMarketingSettings hybridSettings;
  final AutoMarketingGateState gateState;

  @override
  State<_MarketingAutoDecisionContent> createState() =>
      _MarketingAutoDecisionContentState();
}

class _MarketingAutoDecisionContentState
    extends State<_MarketingAutoDecisionContent> {
  Timer? _autoTimer;
  int? _countdownRemaining;
  bool _countdownCancelled = false;

  @override
  void initState() {
    super.initState();
    final countdownSecs = AutoModeConfig.autoCountdownSecondsForConfidence(
      widget.decision.confidence,
    );
    if (widget.decision.decisionLevel == 'auto' &&
        widget.hybridSettings.autoExecutionEnabled &&
        countdownSecs != null &&
        !widget.gateState.autoShieldEnabled) {
      _countdownRemaining = countdownSecs;
      _autoTimer = Timer.periodic(const Duration(seconds: 1), _onCountdownTick);
    }
  }

  void _onCountdownTick(Timer t) {
    if (!mounted || _countdownCancelled) {
      t.cancel();
      return;
    }
    final r = (_countdownRemaining ?? 0) - 1;
    if (r <= 0) {
      t.cancel();
      if (mounted) {
        setState(() => _countdownRemaining = null);
      }
      _runSendNow(markAutoExecuted: true);
    } else if (mounted) {
      setState(() => _countdownRemaining = r);
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }

  void _stopCountdown() {
    _countdownCancelled = true;
    _autoTimer?.cancel();
    _autoTimer = null;
    if (mounted) {
      setState(() => _countdownRemaining = null);
    }
  }

  String _hourLabel() {
    final loc = Localizations.localeOf(context).toString();
    final d = DateTime(2024, 6, 15, widget.decision.bestHour % 24);
    return DateFormat.jm(loc).format(d);
  }

  String _audienceLabel(AppLocalizations loc) {
    switch (widget.decision.audienceSegment) {
      case 'warm':
        return loc.autoDecisionAudienceWarm;
      case 'cold':
        return loc.autoDecisionAudienceCold;
      case 'all':
        return loc.autoDecisionAudienceAll;
      default:
        return loc.autoDecisionAudienceActive;
    }
  }

  NotificationPredictionLogMeta _predictionMeta() {
    final f = CaptionFactorAnalyzer.factorsMap(
      widget.decision.captionText,
      widget.area,
    );
    return NotificationPredictionLogMeta(
      predictedScore: widget.decision.confidence,
      factors: NotificationLearningFactors(
        hasEmoji: f['hasEmoji'] ?? false,
        hasArea: f['hasArea'] ?? false,
        hasUrgency: f['hasUrgency'] ?? false,
        shortText: f['shortText'] ?? false,
      ),
      variantId: widget.decision.captionId,
      trendingAreaAr:
          widget.area.trim().isNotEmpty ? widget.area.trim() : null,
    );
  }

  Future<void> _runSendNow({required bool markAutoExecuted}) async {
    _stopCountdown();
    final parent = widget.parentContext;
    final dec = widget.decision;
    final meta = _predictionMeta();
    final aud = dec.audienceSegment;

    Navigator.of(context).pop();

    if (!parent.mounted) return;
    final logId = await DecisionTrackingService.logDecisionAndReturnId(
      decision: dec,
      chosenCaptionId: dec.captionId,
      chosenAudience: aud,
      chosenTime: DateTime.now().hour,
      override: false,
      decisionLevel: dec.decisionLevel,
    );
    if (!parent.mounted) return;
    await AdminActionService.sendNotification(
      context: parent,
      title: dec.notificationTitle,
      body: dec.notificationBody,
      isAr: widget.isAr,
      source: 'instagram_auto_decision',
      predictionLog: meta,
      trendingAreaAr:
          widget.area.trim().isNotEmpty ? widget.area.trim() : null,
      audienceSegment: aud,
      autoDecisionLogId: logId,
    );
    if (markAutoExecuted && logId != null) {
      await DecisionTrackingService.markAutoExecuted(logId);
    }
  }

  Future<void> _runSchedule() async {
    _stopCountdown();
    final parent = widget.parentContext;
    final dec = widget.decision;
    final meta = _predictionMeta();
    final aud = dec.audienceSegment;

    Navigator.of(context).pop();

    if (!parent.mounted) return;
    final logId = await DecisionTrackingService.logDecisionAndReturnId(
      decision: dec,
      chosenCaptionId: dec.captionId,
      chosenAudience: aud,
      chosenTime: dec.bestHour,
      override: false,
      decisionLevel: dec.decisionLevel,
    );
    if (!parent.mounted) return;
    await AdminActionService.queueScheduledNotification(
      context: parent,
      title: dec.notificationTitle,
      body: dec.notificationBody,
      scheduledAt: dec.suggestedScheduleAt,
      isAr: widget.isAr,
      source: 'instagram_auto_decision',
      predictionLog: meta,
      trendingAreaAr:
          widget.area.trim().isNotEmpty ? widget.area.trim() : null,
      audienceSegment: aud,
      autoDecisionLogId: logId,
    );
  }

  Future<void> _openEditPreview() async {
    _stopCountdown();
    final parent = widget.parentContext;
    final dec = widget.decision;
    final meta = _predictionMeta();
    final aud = dec.audienceSegment;

    Navigator.of(context).pop();
    if (!parent.mounted) return;

    await showNotificationPreviewDialog(
      context: parent,
      initialMode: NotificationSendMode.broadcast,
      broadcastTitle: dec.notificationTitle,
      broadcastBody: dec.notificationBody,
      samplePersonalizedTitle: '',
      samplePersonalizedBody: '',
      isAr: widget.isAr,
      showPersonalizedOption: false,
      onConfirm:
          (mode, title, body, {
            abBroadcastVariants,
            sendPredictedBestOnly,
            sendPredictedMeta,
            abPredictionByCanonical,
            trendingAreaArForAb,
            scheduledSendAt,
            audienceSegment,
          }) async {
        if (!parent.mounted) return;
        final seg = audienceSegment?.trim().isNotEmpty == true
            ? audienceSegment
            : aud;
        final chosenCap = DecisionTrackingService.inferCaptionIdFromBody(
          body,
          dec.captionId,
        );
        final chosenHr = scheduledSendAt?.hour ?? DateTime.now().hour;
        final decisionLogId = await DecisionTrackingService.logDecisionAndReturnId(
          decision: dec,
          chosenCaptionId: chosenCap,
          chosenAudience: seg ?? aud,
          chosenTime: chosenHr,
          override: true,
          decisionLevel: dec.decisionLevel,
          chosenBodyForDiff: body,
        );
        if (!parent.mounted) return;
        final log = sendPredictedMeta ?? meta;
        if (scheduledSendAt != null) {
          await AdminActionService.queueScheduledNotification(
            context: parent,
            title: title,
            body: body,
            scheduledAt: scheduledSendAt,
            isAr: widget.isAr,
            source: 'instagram_auto_decision',
            predictionLog: log,
            trendingAreaAr: trendingAreaArForAb ?? widget.area.trim(),
            audienceSegment: seg,
            autoDecisionLogId: decisionLogId,
          );
        } else {
          await AdminActionService.sendNotification(
            context: parent,
            title: title,
            body: body,
            isAr: widget.isAr,
            source: 'instagram_auto_decision',
            predictionLog: log,
            trendingAreaAr: trendingAreaArForAb ?? widget.area.trim(),
            audienceSegment: seg,
            autoDecisionLogId: decisionLogId,
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final dec = widget.decision;
    final lvl = dec.decisionLevel;
    final pctCtr = (dec.expectedCtr * 100).clamp(0, 100).round();
    final pctConf = (dec.confidence * 100).clamp(0, 100).round();

    String titleText;
    final List<Widget> headerBits = [];
    if (lvl == 'auto') {
      titleText = loc.hybridAutoTitle;
      headerBits.add(
        Text(
          loc.hybridAutoSubtitle,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
        ),
      );
    } else if (lvl == 'review') {
      titleText = loc.hybridReviewTitle;
    } else {
      titleText = loc.hybridManualTitle;
      headerBits.add(
        Text(
          loc.hybridManualSubtitle,
          style: TextStyle(fontSize: 13, color: Colors.orange.shade900),
        ),
      );
    }

    if (lvl == 'auto' &&
        widget.hybridSettings.autoExecutionEnabled &&
        _countdownRemaining != null &&
        _countdownRemaining! > 0 &&
        !_countdownCancelled) {
      headerBits.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            loc.hybridAutoCountdown(_countdownRemaining!),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.deepOrange.shade800,
            ),
          ),
        ),
      );
    }

    final actions = <Widget>[];

    if (lvl == 'auto') {
      actions.add(
        TextButton(
          onPressed: () {
            _stopCountdown();
            Navigator.of(context).pop();
          },
          child: Text(loc.cancel),
        ),
      );
      actions.add(
        FilledButton(
          onPressed: () => _runSendNow(markAutoExecuted: false),
          child: Text(loc.hybridRunNow),
        ),
      );
    } else if (lvl == 'review') {
      actions.add(
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.cancel),
        ),
      );
      actions.add(
        TextButton(
          onPressed: _openEditPreview,
          child: Text(loc.autoDecisionEdit),
        ),
      );
      actions.add(
        FilledButton.tonal(
          onPressed: _runSchedule,
          child: Text(loc.autoDecisionApproveSchedule),
        ),
      );
      actions.add(
        FilledButton(
          onPressed: () => _runSendNow(markAutoExecuted: false),
          child: Text(loc.autoDecisionSendNow),
        ),
      );
    } else {
      actions.add(
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(loc.cancel),
        ),
      );
      actions.add(
        FilledButton(
          onPressed: _openEditPreview,
          child: Text(loc.hybridEditOnly),
        ),
      );
    }

    return AlertDialog(
      title: Text(titleText),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.gateState.autoShieldEnabled) ...[
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade700, width: 1.2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loc.hybridAutoShieldPausedTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: Colors.red.shade900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      loc.hybridAutoShieldPausedBody,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: Colors.red.shade900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            ...headerBits,
            if (headerBits.isNotEmpty) const SizedBox(height: 10),
            Text(
              loc.autoDecisionBestTime(_hourLabel()),
              style: const TextStyle(fontSize: 15, height: 1.35),
            ),
            const SizedBox(height: 6),
            Text(
              loc.autoDecisionAudience(_audienceLabel(loc)),
              style: const TextStyle(fontSize: 15, height: 1.35),
            ),
            const SizedBox(height: 6),
            Text(
              loc.autoDecisionCaptionVariant(dec.captionId),
              style: const TextStyle(fontSize: 15, height: 1.35),
            ),
            const SizedBox(height: 10),
            Text(
              loc.autoDecisionExpectedCtr(pctCtr),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.blueGrey.shade900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              loc.autoDecisionConfidence(pctConf),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.blueGrey.shade900,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              loc.autoDecisionReasonLabel,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              dec.reason,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: Colors.grey.shade800,
              ),
            ),
          ],
        ),
      ),
      actions: actions,
    );
  }
}
