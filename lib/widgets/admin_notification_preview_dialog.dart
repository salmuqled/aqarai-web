import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/models/personalized_trending_payload.dart';
import 'package:aqarai_app/services/admin_action_service.dart';
import 'package:aqarai_app/services/notification_prediction_service.dart';
import 'package:aqarai_app/services/notification_decision_service.dart';
import 'package:aqarai_app/services/notification_strategy_service.dart';
import 'package:aqarai_app/services/revenue_prediction_service.dart';
import 'package:aqarai_app/services/smart_notification_service.dart';

String _formatKwd(double v, bool isAr) {
  final x = v.isFinite ? v : 0.0;
  final fmt = NumberFormat('#,##0', isAr ? 'ar' : 'en');
  return '${fmt.format(x.round())} KWD';
}

String _fmtExpectedCount(double v) {
  if (!v.isFinite || v < 0) return '0';
  return v.round().toString();
}

/// وضع الإرسال بعد تأكيد الأدمن في المعاينة.
enum NotificationSendMode {
  /// نفس النص لجميع المستخدمين (قابل للتعديل).
  broadcast,

  /// نص يُولَّد لكل مستخدم على الخادم (حسب التفضيلات والاتجاه العام).
  personalized,
}

/// معاينة + اختيار عام/مخصّص؛ لا إرسال تلقائي — يُنفَّذ فقط من [onConfirm].
///
/// عند [showPersonalizedOption] = false يُعرض البث العام فقط (للتوافق مع مسارات قديمة).
///
/// عند [abBroadcastVariants] بطول ≥ 2 يُجرى بث A/B (قراءة فقط) ويُمرَّر القائمة في [onConfirm].
///
/// [broadcastPredictions]: من [NotificationPredictionService]؛ ترتيب العرض قد يُعاد حسب العائد المتوقع عند تمرير [notificationRevenueBaselines].
Future<void> showNotificationPreviewDialog({
  required BuildContext context,
  required NotificationSendMode initialMode,
  required String broadcastTitle,
  required String broadcastBody,
  required String samplePersonalizedTitle,
  required String samplePersonalizedBody,
  required bool isAr,
  bool showPersonalizedOption = true,
  List<SmartNotificationSuggestion>? abBroadcastVariants,
  List<PredictedNotification>? broadcastPredictions,
  Map<String, NotificationPredictionLogMeta>? abPredictionMetaByCanonical,
  String? trendingAreaArForAb,
  NotificationRevenueBaselines? notificationRevenueBaselines,
  int? estimatedNotificationAudienceSize,
  int? pastNotificationLogsSampleSize,
  required Future<void> Function(
    NotificationSendMode mode,
    String title,
    String body, {
    List<SmartNotificationSuggestion>? abBroadcastVariants,
    SmartNotificationSuggestion? sendPredictedBestOnly,
    NotificationPredictionLogMeta? sendPredictedMeta,
    Map<String, NotificationPredictionLogMeta>? abPredictionByCanonical,
    String? trendingAreaArForAb,
    DateTime? scheduledSendAt,
    String? audienceSegment,
  }) onConfirm,
}) async {
  if (!context.mounted) return;

  final titleCtrl = TextEditingController(text: broadcastTitle);
  final bodyCtrl = TextEditingController(text: broadcastBody);

  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        return _PreviewDialogBody(
          isAr: isAr,
          initialMode: initialMode,
          showPersonalizedOption: showPersonalizedOption,
          titleCtrl: titleCtrl,
          bodyCtrl: bodyCtrl,
          samplePersonalizedTitle: samplePersonalizedTitle,
          samplePersonalizedBody: samplePersonalizedBody,
          abBroadcastVariants: abBroadcastVariants,
          broadcastPredictions: broadcastPredictions,
          abPredictionMetaByCanonical: abPredictionMetaByCanonical,
          trendingAreaArForAb: trendingAreaArForAb,
          notificationRevenueBaselines: notificationRevenueBaselines,
          estimatedNotificationAudienceSize:
              estimatedNotificationAudienceSize,
          pastNotificationLogsSampleSize: pastNotificationLogsSampleSize,
          onConfirm: onConfirm,
          rootContext: context,
        );
      },
    );
  } finally {
    titleCtrl.dispose();
    bodyCtrl.dispose();
  }
}

class _PreviewDialogBody extends StatefulWidget {
  const _PreviewDialogBody({
    required this.isAr,
    required this.initialMode,
    required this.showPersonalizedOption,
    required this.titleCtrl,
    required this.bodyCtrl,
    required this.samplePersonalizedTitle,
    required this.samplePersonalizedBody,
    this.abBroadcastVariants,
    this.broadcastPredictions,
    this.abPredictionMetaByCanonical,
    this.trendingAreaArForAb,
    this.notificationRevenueBaselines,
    this.estimatedNotificationAudienceSize,
    this.pastNotificationLogsSampleSize,
    required this.onConfirm,
    required this.rootContext,
  });

  final bool isAr;
  final NotificationSendMode initialMode;
  final bool showPersonalizedOption;
  final TextEditingController titleCtrl;
  final TextEditingController bodyCtrl;
  final String samplePersonalizedTitle;
  final String samplePersonalizedBody;
  final List<SmartNotificationSuggestion>? abBroadcastVariants;
  final List<PredictedNotification>? broadcastPredictions;
  final Map<String, NotificationPredictionLogMeta>? abPredictionMetaByCanonical;
  final String? trendingAreaArForAb;
  final NotificationRevenueBaselines? notificationRevenueBaselines;
  final int? estimatedNotificationAudienceSize;
  final int? pastNotificationLogsSampleSize;
  final Future<void> Function(
    NotificationSendMode mode,
    String title,
    String body, {
    List<SmartNotificationSuggestion>? abBroadcastVariants,
    SmartNotificationSuggestion? sendPredictedBestOnly,
    NotificationPredictionLogMeta? sendPredictedMeta,
    Map<String, NotificationPredictionLogMeta>? abPredictionByCanonical,
    String? trendingAreaArForAb,
    DateTime? scheduledSendAt,
    String? audienceSegment,
  }) onConfirm;
  final BuildContext rootContext;

  @override
  State<_PreviewDialogBody> createState() => _PreviewDialogBodyState();
}

class _PreviewDialogBodyState extends State<_PreviewDialogBody> {
  late NotificationSendMode _mode;

  /// اختيار يدوي: اختيار نسخة ثم «إرسال المحدد».
  bool _manualPickMode = false;

  SmartNotificationSuggestion? _manualSelected;

  NotificationDecision? _decision;

  /// طبقة ملخص التوصية قبل عرض كل النسخ (لا إرسال تلقائي).
  late bool _showSmartRecommendationIntro;

  late final Future<NotificationStrategy?> _strategyFuture;
  NotificationStrategy? _strategyCache;

  bool get _isAbBroadcast =>
      widget.abBroadcastVariants != null &&
      widget.abBroadcastVariants!.length >= 2;

  bool get _hasPredictionUi =>
      _isAbBroadcast &&
      widget.broadcastPredictions != null &&
      widget.broadcastPredictions!.isNotEmpty;

  SmartNotificationSuggestion? _suggestionForCanonical(String text) {
    final list = widget.abBroadcastVariants;
    if (list == null) return null;
    for (final v in list) {
      if (NotificationPredictionService.canonicalVariantText(v.title, v.body) ==
          text) {
        return v;
      }
    }
    return null;
  }

  SmartNotificationSuggestion? get _predictedBestSuggestion {
    if (!_hasPredictionUi) return null;
    if (_decision != null) {
      return _suggestionForCanonical(_decision!.selectedText);
    }
    if (_useRevenueRanking) {
      final ord = _predictionsOrderedByRevenue();
      if (ord.isEmpty) return null;
      return _suggestionForCanonical(ord.first.value.text);
    }
    final first = widget.broadcastPredictions!.first;
    return _suggestionForCanonical(first.text);
  }

  NotificationPredictionLogMeta? _metaForSuggestion(SmartNotificationSuggestion s) {
    final m = widget.abPredictionMetaByCanonical;
    if (m == null) return null;
    final c = NotificationPredictionService.canonicalVariantText(s.title, s.body);
    return m[c];
  }

  @override
  void initState() {
    super.initState();
    _mode = widget.showPersonalizedOption
        ? widget.initialMode
        : NotificationSendMode.broadcast;
    _decision = _computeDecision();
    _showSmartRecommendationIntro = _decision != null;
    _manualSelected = _initialManualSelection();
    _strategyFuture = _loadStrategyFuture();
    _strategyFuture.then((s) {
      if (mounted) {
        setState(() => _strategyCache = s);
      }
    });
  }

  Future<NotificationStrategy?> _loadStrategyFuture() async {
    final d = _decision;
    final b = widget.notificationRevenueBaselines;
    if (d == null || b == null) return null;
    try {
      return await NotificationStrategyService.build(
        db: FirebaseFirestore.instance,
        decision: d,
        baselines: b,
        estimatedAudienceSize: _estimatedAudience,
      );
    } catch (_) {
      return null;
    }
  }

  NotificationDecision? _computeDecision() {
    if (!_useRevenueRanking) return null;
    final preds = widget.broadcastPredictions!;
    final b = widget.notificationRevenueBaselines!;
    final titles = <String>[];
    final bodies = <String>[];
    final revenues = <PredictedRevenue>[];
    for (final p in preds) {
      final s = _suggestionForCanonical(p.text);
      titles.add(s?.title ?? '');
      bodies.add(s?.body ?? '');
      revenues.add(
        RevenuePredictionService.predictRevenueWithBoost(
          predictedCTR: p.predictedCTR,
          baselines: b,
          estimatedAudienceSize: _estimatedAudience,
          variantTitle: s?.title ?? '',
          variantBody: s?.body ?? '',
          trendingAreaAr: widget.trendingAreaArForAb,
        ),
      );
    }
    return NotificationDecisionService.chooseBestVariant(
      variants: preds,
      revenues: revenues,
      isAr: widget.isAr,
      pastLogsSampleSize: widget.pastNotificationLogsSampleSize ?? 0,
      trendingAreaAr: widget.trendingAreaArForAb,
      variantTitles: titles,
      variantBodies: bodies,
    );
  }

  int get _estimatedAudience =>
      (widget.estimatedNotificationAudienceSize != null &&
              widget.estimatedNotificationAudienceSize! > 0)
          ? widget.estimatedNotificationAudienceSize!
          : 5000;

  /// عند توفر أساسيات العائد نرتّب حسب [PredictedRevenue.expectedRevenue] ونبرز الأفضل عائداً.
  bool get _useRevenueRanking =>
      _hasPredictionUi && widget.notificationRevenueBaselines != null;

  SmartNotificationSuggestion? _bestVariantByRevenueAssumedCtr() {
    final list = widget.abBroadcastVariants;
    final rb = widget.notificationRevenueBaselines;
    if (list == null || rb == null || list.isEmpty) return null;
    SmartNotificationSuggestion? best;
    var bestRev = -1.0;
    for (final v in list) {
      final r = RevenuePredictionService.predictRevenueWithBoost(
        predictedCTR: 0.05,
        baselines: rb,
        estimatedAudienceSize: _estimatedAudience,
        variantTitle: v.title,
        variantBody: v.body,
        trendingAreaAr: widget.trendingAreaArForAb,
      ).expectedRevenue;
      if (r > bestRev) {
        bestRev = r;
        best = v;
      }
    }
    return best ?? list.first;
  }

  SmartNotificationSuggestion? _initialManualSelection() {
    final list = widget.abBroadcastVariants;
    if (list == null || list.isEmpty) return null;
    if (_decision != null) {
      return _suggestionForCanonical(_decision!.selectedText) ?? list.first;
    }
    if (_useRevenueRanking) {
      final ord = _predictionsOrderedByRevenue();
      if (ord.isEmpty) return list.first;
      return _suggestionForCanonical(ord.first.value.text) ?? list.first;
    }
    if (widget.notificationRevenueBaselines != null) {
      return _bestVariantByRevenueAssumedCtr();
    }
    return list.first;
  }

  List<MapEntry<int, PredictedNotification>> _predictionsOrderedByRevenue() {
    final preds = widget.broadcastPredictions!;
    final b = widget.notificationRevenueBaselines!;
    final audience = _estimatedAudience;
    final ta = widget.trendingAreaArForAb;

    double revFor(PredictedNotification p) {
      final s = _suggestionForCanonical(p.text);
      return RevenuePredictionService.predictRevenueWithBoost(
        predictedCTR: p.predictedCTR,
        baselines: b,
        estimatedAudienceSize: audience,
        variantTitle: s?.title ?? '',
        variantBody: s?.body ?? '',
        trendingAreaAr: ta,
      ).expectedRevenue;
    }

    final entries = preds.asMap().entries.toList();
    entries.sort((a, b) => revFor(b.value).compareTo(revFor(a.value)));
    return entries;
  }

  PredictedRevenue _revenueBreakdownForPrediction(PredictedNotification p) {
    final b = widget.notificationRevenueBaselines!;
    final s = _suggestionForCanonical(p.text);
    return RevenuePredictionService.predictRevenueWithBoost(
      predictedCTR: p.predictedCTR,
      baselines: b,
      estimatedAudienceSize: _estimatedAudience,
      variantTitle: s?.title ?? '',
      variantBody: s?.body ?? '',
      trendingAreaAr: widget.trendingAreaArForAb,
    );
  }

  SmartNotificationSuggestion? _topPickForManualMode() {
    final list = widget.abBroadcastVariants;
    if (list == null || list.isEmpty) return null;
    if (_decision != null) {
      return _suggestionForCanonical(_decision!.selectedText) ?? list.first;
    }
    if (_useRevenueRanking) {
      final ord = _predictionsOrderedByRevenue();
      if (ord.isEmpty) return list.first;
      return _suggestionForCanonical(ord.first.value.text) ?? list.first;
    }
    if (widget.notificationRevenueBaselines != null) {
      return _bestVariantByRevenueAssumedCtr();
    }
    return list.first;
  }

  List<Widget> _buildPredictionVariantCards(bool isAr) {
    final preds = widget.broadcastPredictions!;
    final showRev = widget.notificationRevenueBaselines != null;

    Widget oneCard({
      required PredictedNotification p,
      required bool isBest,
      required int labelFallbackIndex,
    }) {
      final s = _suggestionForCanonical(p.text);
      final label = s?.variantId ?? 'v$labelFallbackIndex';
      final pct = (p.predictedCTR * 100).toStringAsFixed(0);
      final rev = showRev ? _revenueBreakdownForPrediction(p) : null;

      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isBest ? const Color(0xFFE8F5E9) : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isBest ? Colors.green.shade400 : Colors.grey.shade300,
              width: isBest ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isBest)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: Icon(
                          showRev ? Icons.local_fire_department : Icons.star_rounded,
                          size: 20,
                          color: showRev
                              ? Colors.deepOrange.shade700
                              : Colors.green.shade800,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        showRev
                            ? (isAr
                                ? '${isBest ? 'أعلى عائد متوقع' : 'نسخة'} · $label · CTR $pct%'
                                : '${isBest ? 'Top expected revenue' : 'Variant'} · $label · CTR $pct%')
                            : '${isAr ? 'الأفضل تنبؤاً' : 'Top pick'} · $label · $pct%',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.blueGrey.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
                if (rev != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    isAr
                        ? '💰 العائد المتوقع: ${_formatKwd(rev.expectedRevenue, isAr)}'
                        : '💰 Expected revenue: ${_formatKwd(rev.expectedRevenue, isAr)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Colors.green.shade900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isAr
                        ? '👥 تحويلات متوقعة: ${_fmtExpectedCount(rev.expectedConversions)}'
                        : '👥 Expected conversions: ${_fmtExpectedCount(rev.expectedConversions)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                  Text(
                    isAr
                        ? '👆 نقرات متوقعة: ${_fmtExpectedCount(rev.expectedClicks)}'
                        : '👆 Expected clicks: ${_fmtExpectedCount(rev.expectedClicks)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                ],
                if (s != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    s.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s.body,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: Colors.grey.shade900,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  Text(
                    p.text,
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    if (_useRevenueRanking) {
      final ord = _predictionsOrderedByRevenue();
      return ord
          .asMap()
          .entries
          .map(
            (me) => oneCard(
              p: me.value.value,
              isBest: me.key == 0,
              labelFallbackIndex: me.value.key,
            ),
          )
          .toList();
    }

    return preds
        .asMap()
        .entries
        .map(
          (e) => oneCard(
            p: e.value,
            isBest: e.key == 0,
            labelFallbackIndex: e.key,
          ),
        )
        .toList();
  }

  List<Widget> _buildAbVariantsWithoutPrediction(bool isAr) {
    final variants = widget.abBroadcastVariants!;
    final rb = widget.notificationRevenueBaselines;

    var bestIdx = 0;
    var bestRev = -1.0;
    if (rb != null) {
      for (var i = 0; i < variants.length; i++) {
        final r = RevenuePredictionService.predictRevenueWithBoost(
          predictedCTR: 0.05,
          baselines: rb,
          estimatedAudienceSize: _estimatedAudience,
          variantTitle: variants[i].title,
          variantBody: variants[i].body,
          trendingAreaAr: widget.trendingAreaArForAb,
        ).expectedRevenue;
        if (r > bestRev) {
          bestRev = r;
          bestIdx = i;
        }
      }
    }

    return variants.asMap().entries.map((e) {
      final v = e.value;
      final label = v.variantId ?? 'v${e.key}';
      final isBest = rb != null && e.key == bestIdx;
      final rev = rb != null
          ? RevenuePredictionService.predictRevenueWithBoost(
              predictedCTR: 0.05,
              baselines: rb,
              estimatedAudienceSize: _estimatedAudience,
              variantTitle: v.title,
              variantBody: v.body,
              trendingAreaAr: widget.trendingAreaArForAb,
            )
          : null;

      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isBest ? const Color(0xFFE8F5E9) : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isBest ? Colors.green.shade400 : Colors.grey.shade300,
              width: isBest ? 2 : 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (isBest)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: Icon(
                          Icons.local_fire_department,
                          size: 20,
                          color: Colors.deepOrange.shade700,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        rb != null
                            ? (isAr
                                ? '${isBest ? 'أعلى عائد (CTR افتراضي 5%)' : 'نسخة'} · $label'
                                : '${isBest ? 'Top revenue (CTR assumed 5%)' : 'Variant'} · $label')
                            : '${isAr ? 'نسخة' : 'Variant'} $label',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.blueGrey.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
                if (rev != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    isAr
                        ? '💰 العائد المتوقع: ${_formatKwd(rev.expectedRevenue, isAr)}'
                        : '💰 Expected revenue: ${_formatKwd(rev.expectedRevenue, isAr)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Colors.green.shade900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isAr
                        ? '👥 تحويلات متوقعة: ${_fmtExpectedCount(rev.expectedConversions)}'
                        : '👥 Expected conversions: ${_fmtExpectedCount(rev.expectedConversions)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                  Text(
                    isAr
                        ? '👆 نقرات متوقعة: ${_fmtExpectedCount(rev.expectedClicks)}'
                        : '👆 Expected clicks: ${_fmtExpectedCount(rev.expectedClicks)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  v.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  v.body,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: Colors.grey.shade900,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  Future<void> _sendPredictedBest() async {
    final s = _predictedBestSuggestion;
    if (s == null) return;
    Navigator.of(context).pop();
    if (widget.rootContext.mounted) {
      await widget.onConfirm(
        NotificationSendMode.broadcast,
        '',
        '',
        sendPredictedBestOnly: s,
        sendPredictedMeta: _metaForSuggestion(s),
        trendingAreaArForAb: widget.trendingAreaArForAb,
      );
    }
  }

  String? _audienceSegmentForSend() {
    final seg = _strategyCache?.bestAudience;
    if (seg == null || seg == 'all') return null;
    return seg;
  }

  Future<void> _sendDecisionApproved() async {
    final d = _decision;
    if (d == null) return;
    final s = _suggestionForCanonical(d.selectedText) ?? _predictedBestSuggestion;
    if (s == null) return;
    Navigator.of(context).pop();
    if (widget.rootContext.mounted) {
      await widget.onConfirm(
        NotificationSendMode.broadcast,
        '',
        '',
        sendPredictedBestOnly: s,
        sendPredictedMeta: _metaForSuggestion(s),
        trendingAreaArForAb: widget.trendingAreaArForAb,
        audienceSegment: _audienceSegmentForSend(),
      );
    }
  }

  Future<void> _scheduleDecision() async {
    final d = _decision;
    if (d == null) return;
    final s = _suggestionForCanonical(d.selectedText) ?? _predictedBestSuggestion;
    if (s == null) return;
    final st = _strategyCache ?? await _strategyFuture;
    if (!mounted) return;
    final hour = st?.bestHour ?? 19;
    final when = NotificationStrategyService.nextLocalSendAt(hour);
    final seg = st?.bestAudience;
    Navigator.of(context).pop();
    if (widget.rootContext.mounted) {
      await widget.onConfirm(
        NotificationSendMode.broadcast,
        '',
        '',
        sendPredictedBestOnly: s,
        sendPredictedMeta: _metaForSuggestion(s),
        trendingAreaArForAb: widget.trendingAreaArForAb,
        scheduledSendAt: when,
        audienceSegment:
            seg != null && seg != 'all' ? seg : null,
      );
    }
  }

  String _segmentUiLabel(bool isAr, String seg) {
    switch (seg) {
      case 'active':
        return isAr ? 'نشطون (<٧ أيام)' : 'Active (<7d)';
      case 'warm':
        return isAr ? 'دافئون (٧–٣٠ يوماً)' : 'Warm (7–30d)';
      case 'cold':
        return isAr ? 'باردون (>٣٠ يوماً)' : 'Cold (>30d)';
      default:
        return isAr ? 'جميع المستخدمين' : 'All users';
    }
  }

  Widget _buildSmartRecommendationSection(bool isAr) {
    final d = _decision!;
    final s = _suggestionForCanonical(d.selectedText);
    final pctCtr = (d.predictedCTR * 100).toStringAsFixed(0);
    final confPct = (d.confidence * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '💡 ',
              style: TextStyle(fontSize: 16, color: Colors.amber.shade800),
            ),
            Expanded(
              child: Text(
                isAr ? 'توصية ذكية' : 'Smart recommendation',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  color: Colors.indigo.shade900,
                ),
              ),
            ),
            Text(
              '🔥',
              style: TextStyle(fontSize: 16, color: Colors.deepOrange.shade700),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isAr ? 'موصى به بواسطة النظام' : 'Recommended by system',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.green.shade800,
          ),
        ),
        const SizedBox(height: 10),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.indigo.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.indigo.shade100),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (s != null) ...[
                  Text(
                    s.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    s.body,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: Colors.grey.shade900,
                    ),
                  ),
                ] else
                  Text(
                    d.selectedText,
                    style: const TextStyle(fontSize: 13),
                  ),
                const SizedBox(height: 10),
                Text(
                  isAr
                      ? '💰 العائد المتوقع: ${_formatKwd(d.expectedRevenue, isAr)}'
                      : '💰 Expected revenue: ${_formatKwd(d.expectedRevenue, isAr)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Colors.green.shade900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isAr
                      ? '📈 CTR المتوقع: $pctCtr% · ثقة: $confPct%'
                      : '📈 Predicted CTR: $pctCtr% · Confidence: $confPct%',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                ),
                const SizedBox(height: 8),
                Text(
                  d.reason,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: Colors.blueGrey.shade800,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        FutureBuilder<NotificationStrategy?>(
          future: _strategyFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: const LinearProgressIndicator(minHeight: 4),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _sendDecisionApproved,
                        child: Text(
                          isAr ? 'إرسال الآن' : 'Send now',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => setState(() {
                          _showSmartRecommendationIntro = false;
                        }),
                        child: Text(
                          isAr ? 'تعديل' : 'Edit',
                        ),
                      ),
                    ],
                  ),
                ],
              );
            }
            final st = snap.data;
            if (st == null) {
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _sendDecisionApproved,
                    child: Text(
                      isAr ? 'موافق وإرسال' : 'Approve & send',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      _showSmartRecommendationIntro = false;
                    }),
                    child: Text(
                      isAr ? 'تعديل / اختيار يدوي' : 'Edit / manual choice',
                    ),
                  ),
                ],
              );
            }

            final timeConfPct = (st.timeConfidence * 100).round();
            final stratConfPct = (st.confidence * 100).round();
            final whenNext = NotificationStrategyService.nextLocalSendAt(
              st.bestHour,
            );
            final timeFmt =
                '${whenNext.hour.toString().padLeft(2, '0')}:${whenNext.minute.toString().padLeft(2, '0')}';

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isAr ? '💡 استراتيجية ذكية' : '💡 Smart strategy',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: Colors.teal.shade900,
                  ),
                ),
                const SizedBox(height: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.teal.shade100),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          isAr
                              ? '🕐 أفضل وقت تقريبي: الساعة ${st.bestHour}:00 (تقدير النشاط) — مثال إرسال: $timeFmt'
                              : '🕐 Best hour (activity): ${st.bestHour}:00 — next slot e.g. $timeFmt',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: Colors.blueGrey.shade900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          isAr
                              ? '⏱️ ثقة الوقت: $timeConfPct%'
                              : '⏱️ Time confidence: $timeConfPct%',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isAr
                              ? '👥 أفضل جمهور: ${_segmentUiLabel(isAr, st.bestAudience)} (~${st.audienceEstimatedSize})'
                              : '👥 Best audience: ${_segmentUiLabel(isAr, st.bestAudience)} (~${st.audienceEstimatedSize})',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: Colors.blueGrey.shade900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isAr
                              ? '💰 عائد متوقع (مع الشريحة): ${_formatKwd(st.expectedRevenue, isAr)}'
                              : '💰 Expected revenue (segment-adjusted): ${_formatKwd(st.expectedRevenue, isAr)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: Colors.green.shade900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isAr
                              ? '📊 ثقة الاستراتيجية: $stratConfPct%'
                              : '📊 Strategy confidence: $stratConfPct%',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: _scheduleDecision,
                      child: Text(
                        isAr ? 'موافق وجدولة' : 'Approve & schedule',
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: _sendDecisionApproved,
                      child: Text(
                        isAr ? 'إرسال الآن' : 'Send now',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () => setState(() {
                        _showSmartRecommendationIntro = false;
                      }),
                      child: Text(isAr ? 'تعديل' : 'Edit'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: _sendAbSplit,
            child: Text(
              isAr
                  ? 'إرسال الكل كاختبار A/B'
                  : 'Send all as A/B test',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _sendManualSelected() async {
    final s = _manualSelected;
    if (s == null) return;
    Navigator.of(context).pop();
    if (widget.rootContext.mounted) {
      await widget.onConfirm(
        NotificationSendMode.broadcast,
        '',
        '',
        sendPredictedBestOnly: s,
        sendPredictedMeta: _metaForSuggestion(s),
        trendingAreaArForAb: widget.trendingAreaArForAb,
      );
    }
  }

  Future<void> _sendAbSplit() async {
    Navigator.of(context).pop();
    if (widget.rootContext.mounted) {
      await widget.onConfirm(
        NotificationSendMode.broadcast,
        '',
        '',
        abBroadcastVariants: widget.abBroadcastVariants,
        abPredictionByCanonical: widget.abPredictionMetaByCanonical,
        trendingAreaArForAb: widget.trendingAreaArForAb,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;

    return AlertDialog(
      title: Text(isAr ? 'معاينة الإشعار' : 'Notification preview'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showPersonalizedOption) ...[
              Text(
                isAr ? 'نوع الإرسال' : 'Send type',
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 8),
              SegmentedButton<NotificationSendMode>(
                segments: [
                  ButtonSegment(
                    value: NotificationSendMode.broadcast,
                    label: Text(
                      isAr ? 'عام' : 'Broadcast',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  ButtonSegment(
                    value: NotificationSendMode.personalized,
                    label: Text(
                      isAr ? 'مخصّص' : 'Personalized',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) {
                  setState(() => _mode = s.first);
                },
              ),
              const SizedBox(height: 6),
              Text(
                _mode == NotificationSendMode.broadcast
                    ? (isAr
                        ? 'إشعار عام لجميع المستخدمين'
                        : 'Same message for all users')
                    : (isAr
                        ? 'إشعار مخصّص لكل مستخدم (يُبنى على الخادم)'
                        : 'Per-user message (built on server)'),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
              ),
              const SizedBox(height: 14),
            ] else ...[
              Text(
                isAr ? 'إشعار عام' : 'Broadcast',
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                isAr
                    ? 'نفس النص لجميع المستخدمين'
                    : 'Same message for all users',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
              ),
              const SizedBox(height: 14),
            ],
            if (_mode == NotificationSendMode.broadcast) ...[
              if (_isAbBroadcast) ...[
                if (_hasPredictionUi) ...[
                  if (_decision != null &&
                      !_manualPickMode &&
                      _showSmartRecommendationIntro) ...[
                    Text(
                      isAr
                          ? 'لا يُرسل شيء تلقائياً — راجع التوصية ثم اختر «موافق وإرسال» أو غيّر النسخة.'
                          : 'Nothing sends automatically — review the pick, then Approve & send or switch to manual.',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                    ),
                    const SizedBox(height: 10),
                    _buildSmartRecommendationSection(isAr),
                  ] else if (!_manualPickMode) ...[
                    if (_decision != null)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: () => setState(() {
                            _showSmartRecommendationIntro = true;
                          }),
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: Text(
                            isAr
                                ? 'العودة للتوصية الذكية'
                                : 'Back to smart summary',
                          ),
                        ),
                      ),
                    Text(
                      isAr
                          ? 'ترتيب مساعد بالذكاء (من سجلات سابقة + قواعد بسيطة) — لا إرسال تلقائي.'
                          : 'AI-assisted ranking (past logs + simple rules) — nothing sends automatically.',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                    ),
                    const SizedBox(height: 10),
                    ..._buildPredictionVariantCards(isAr),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _predictedBestSuggestion == null
                              ? null
                              : _sendPredictedBest,
                          child: Text(
                            isAr
                                ? (_useRevenueRanking
                                    ? 'إرسال الأعلى عائداً'
                                    : 'إرسال الأفضل تنبؤاً')
                                : (_useRevenueRanking
                                    ? 'Send top revenue'
                                    : 'Send best (CTR)'),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () => setState(() {
                            _manualPickMode = true;
                            _manualSelected ??= _topPickForManualMode();
                          }),
                          child: Text(
                            isAr ? 'اختيار يدوي' : 'Manual choice',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: _sendAbSplit,
                        child: Text(
                          isAr
                              ? 'إرسال الكل كاختبار A/B'
                              : 'Send all as A/B test',
                        ),
                      ),
                    ),
                  ] else if (_manualPickMode) ...[
                    Text(
                      isAr ? 'اختر نسخة للإرسال' : 'Pick a message to send',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ...widget.abBroadcastVariants!.map((v) {
                      final sel = _manualSelected == v;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: sel
                              ? Colors.blue.shade50
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => setState(() => _manualSelected = v),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    sel
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_off,
                                    size: 22,
                                    color: sel
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.grey,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          v.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          v.body,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade800,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            _manualPickMode = false;
                          }),
                          child: Text(isAr ? 'رجوع' : 'Back'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _manualSelected == null
                              ? null
                              : _sendManualSelected,
                          child: Text(
                            isAr ? 'إرسال المحدد' : 'Send selected',
                          ),
                        ),
                      ],
                    ),
                  ],
                ] else ...[
                  Text(
                    isAr
                        ? 'اختبار A/B: يستلم كل مجموعة نسخة مختلفة. (تعذّر تحميل السجلات للتنبؤ — عرض النسخ فقط.)'
                        : 'A/B test: each group gets a different message. (Could not load logs for prediction — variants only.)',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                  const SizedBox(height: 10),
                  ..._buildAbVariantsWithoutPrediction(isAr),
                ],
              ] else ...[
                Text(
                  isAr ? 'العنوان' : 'Title',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: widget.titleCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  isAr ? 'نص الإشعار' : 'Message body',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: widget.bodyCtrl,
                  minLines: 3,
                  maxLines: 6,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ] else ...[
              Text(
                isAr
                    ? 'مثال لنص مخصّص (عيّنة واحدة)'
                    : 'Sample personalized copy',
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.samplePersonalizedTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.samplePersonalizedBody,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: Colors.grey.shade900,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isAr
                    ? 'النص الفعلي يختلف حسب المنطقة/النوع المفضّل لكل مستخدم.'
                    : 'Actual text varies by each user’s preferred area/type.',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              _hasPredictionUi && _mode == NotificationSendMode.broadcast
                  ? (isAr
                      ? 'لن يُرسل شيئاً حتى تختار أحد الخيارات أعلاه (لا إرسال تلقائي).'
                      : 'Nothing sends until you choose an option above (no auto-send).')
                  : (isAr
                      ? 'لن يُرسل شيء حتى تضغط «إرسال».'
                      : 'Nothing is sent until you tap Send.'),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(isAr ? 'إلغاء' : 'Cancel'),
        ),
        if (!(_mode == NotificationSendMode.broadcast && _hasPredictionUi))
          FilledButton(
            onPressed: () async {
              if (_mode == NotificationSendMode.broadcast) {
                if (_isAbBroadcast) {
                  Navigator.of(context).pop();
                  if (widget.rootContext.mounted) {
                    await widget.onConfirm(
                      NotificationSendMode.broadcast,
                      '',
                      '',
                      abBroadcastVariants: widget.abBroadcastVariants,
                    );
                  }
                  return;
                }
                final t = widget.titleCtrl.text.trim();
                final b = widget.bodyCtrl.text.trim();
                if (t.isEmpty || b.isEmpty) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      behavior: SnackBarBehavior.floating,
                      content: Text(
                        isAr
                            ? 'العنوان والنص لا يمكن أن يكونا فارغين.'
                            : 'Title and body cannot be empty.',
                      ),
                    ),
                  );
                  return;
                }
                Navigator.of(context).pop();
                if (widget.rootContext.mounted) {
                  await widget.onConfirm(
                    NotificationSendMode.broadcast,
                    t,
                    b,
                  );
                }
                return;
              }

              Navigator.of(context).pop();
              if (widget.rootContext.mounted) {
                await widget.onConfirm(
                  NotificationSendMode.personalized,
                  '',
                  '',
                );
              }
            },
            child: Text(isAr ? 'إرسال' : 'Send'),
          ),
      ],
    );
  }
}

/// يفتح المعاينة ثم يوجّه الإما لـ [sendGlobalNotification] / إرسال A/B أو [sendPersonalizedNotifications].
///
/// يحمّل سجلات الإشعارات الأخيرة لبناء ترتيب تنبؤي؛ **لا إرسال تلقائي** — تأكيد الأدمن دائماً.
Future<void> openSmartNotificationPreview({
  required BuildContext context,
  required NotificationSendMode initialMode,
  required List<SmartNotificationSuggestion> broadcastVariants,
  required String samplePersonalizedTitle,
  required String samplePersonalizedBody,
  required PersonalizedTrendingPayload personalizedPayload,
  required bool isAr,
}) async {
  if (!context.mounted) return;

  List<PredictedNotification>? broadcastPredictions;
  Map<String, NotificationPredictionLogMeta>? abPredictionMetaByCanonical;
  NotificationRevenueBaselines? revenueBaselines;
  var estimatedNotificationAudience = 5000;
  var pastNotificationLogsSampleSize = 0;
  final taForLearning = personalizedPayload.trendingAreaAr.trim().isEmpty
      ? null
      : personalizedPayload.trendingAreaAr.trim();

  if (broadcastVariants.length >= 2) {
    try {
      final db = FirebaseFirestore.instance;
      final snap = await db
          .collection('notification_logs')
          .orderBy('createdAt', descending: true)
          .limit(200)
          .get();
      final maps = snap.docs.map((d) => d.data()).toList();
      pastNotificationLogsSampleSize = maps.length;
      revenueBaselines = RevenuePredictionService.baselinesFromLogMaps(maps);
      for (final m in maps) {
        final sv = m['sentCount'];
        final n = sv is int ? sv : int.tryParse('$sv') ?? 0;
        if (n > 0) {
          estimatedNotificationAudience = n;
          break;
        }
      }
      final ranked =
          await NotificationPredictionService.predictRankedForSuggestions(
        db: db,
        suggestions: broadcastVariants,
        pastLogs: maps,
        areaNameAr: taForLearning,
      );
      broadcastPredictions = ranked;
      abPredictionMetaByCanonical = {};
      for (final v in broadcastVariants) {
        final c = NotificationPredictionService.canonicalVariantText(
          v.title,
          v.body,
        );
        PredictedNotification? p;
        for (final x in ranked) {
          if (x.text == c) {
            p = x;
            break;
          }
        }
        if (p != null) {
          abPredictionMetaByCanonical[c] = NotificationPredictionLogMeta(
            predictedScore: p.predictedScore,
            factors: p.factors,
            variantId: p.variantId ?? v.variantId,
            trendingAreaAr: taForLearning,
          );
        }
      }
    } catch (_) {
      broadcastPredictions = null;
      abPredictionMetaByCanonical = null;
      revenueBaselines = RevenuePredictionService.baselinesFromLogMaps([]);
    }
  }

  if (!context.mounted) return;

  final first = broadcastVariants.isNotEmpty
      ? broadcastVariants.first
      : const SmartNotificationSuggestion(title: '', body: '');
  await showNotificationPreviewDialog(
    context: context,
    initialMode: initialMode,
    broadcastTitle: first.title,
    broadcastBody: first.body,
    samplePersonalizedTitle: samplePersonalizedTitle,
    samplePersonalizedBody: samplePersonalizedBody,
    isAr: isAr,
    abBroadcastVariants:
        broadcastVariants.length >= 2 ? broadcastVariants : null,
    broadcastPredictions: broadcastPredictions,
    abPredictionMetaByCanonical: abPredictionMetaByCanonical,
    trendingAreaArForAb: taForLearning,
    notificationRevenueBaselines: revenueBaselines,
    estimatedNotificationAudienceSize: broadcastVariants.length >= 2
        ? estimatedNotificationAudience
        : null,
    pastNotificationLogsSampleSize: broadcastVariants.length >= 2
        ? pastNotificationLogsSampleSize
        : null,
    onConfirm: (mode, title, body,
        {abBroadcastVariants,
        sendPredictedBestOnly,
        sendPredictedMeta,
        abPredictionByCanonical,
        trendingAreaArForAb,
        scheduledSendAt,
        audienceSegment}) async {
      if (!context.mounted) return;
      if (mode == NotificationSendMode.broadcast) {
        if (sendPredictedBestOnly != null) {
          if (scheduledSendAt != null) {
            await AdminActionService.queueScheduledNotification(
              context: context,
              title: sendPredictedBestOnly.title,
              body: sendPredictedBestOnly.body,
              scheduledAt: scheduledSendAt,
              isAr: isAr,
              source: 'no_deals_recommendation',
              predictionLog: sendPredictedMeta,
              trendingAreaAr: trendingAreaArForAb ?? taForLearning,
              audienceSegment: audienceSegment,
            );
            return;
          }
          await AdminActionService.sendNotification(
            context: context,
            title: sendPredictedBestOnly.title,
            body: sendPredictedBestOnly.body,
            isAr: isAr,
            source: 'no_deals_recommendation',
            predictionLog: sendPredictedMeta,
            trendingAreaAr: trendingAreaArForAb ?? taForLearning,
            audienceSegment: audienceSegment,
          );
          return;
        }
        final ab = abBroadcastVariants;
        if (ab != null && ab.length >= 2) {
          await AdminActionService.sendAbBroadcast(
            context: context,
            variants: ab,
            isAr: isAr,
            source: 'no_deals_recommendation',
            predictionByCanonicalText: abPredictionByCanonical,
            trendingAreaAr: trendingAreaArForAb ?? taForLearning,
          );
        } else {
          await AdminActionService.sendNotification(
            context: context,
            title: title,
            body: body,
            isAr: isAr,
            source: 'no_deals_recommendation',
          );
        }
      } else {
        await AdminActionService.sendPersonalizedNotifications(
          context: context,
          payload: personalizedPayload,
          isAr: isAr,
          source: 'no_deals_recommendation',
          logTitle: samplePersonalizedTitle,
          logBody: samplePersonalizedBody,
        );
      }
    },
  );
}
