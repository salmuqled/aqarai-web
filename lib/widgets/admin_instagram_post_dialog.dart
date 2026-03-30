import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/services/area_analytics_service.dart';
import 'package:aqarai_app/models/caption_usage_context.dart';
import 'package:aqarai_app/services/caption_learning_service.dart';
import 'package:aqarai_app/services/caption_performance_service.dart';
import 'package:aqarai_app/services/caption_variant_service.dart';
import 'package:aqarai_app/services/instagram_caption_service.dart';
import 'package:aqarai_app/services/post_image_service.dart';
import 'package:aqarai_app/widgets/instagram_post_actions_widget.dart';
import 'package:aqarai_app/widgets/marketing_auto_decision_dialog.dart';

/// Admin: generate branded image + data-driven caption; manual post flow (no in-app image).
Future<void> showAdminInstagramPostGenerator(BuildContext navigatorContext) async {
  final isAr = Localizations.localeOf(navigatorContext).languageCode == 'ar';
  await showDialog<void>(
    context: navigatorContext,
    builder: (ctx) => _AdminInstagramPostDialog(
      navigatorContext: navigatorContext,
      isArabic: isAr,
    ),
  );
}

class _AdminInstagramPostDialog extends StatefulWidget {
  const _AdminInstagramPostDialog({
    required this.navigatorContext,
    required this.isArabic,
  });

  final BuildContext navigatorContext;
  final bool isArabic;

  @override
  State<_AdminInstagramPostDialog> createState() =>
      _AdminInstagramPostDialogState();
}

class _AdminInstagramPostDialogState extends State<_AdminInstagramPostDialog> {
  final _titleCtrl = TextEditingController();
  final _subtitleCtrl = TextEditingController();
  final _areaCtrl = TextEditingController();
  final _propertyTypeCtrl = TextEditingController();
  final _propertyIdCtrl = TextEditingController();
  final _dealsCtrl = TextEditingController(text: '0');

  final _analytics = AreaAnalyticsService();
  Timer? _areaDebounce;

  InstagramDemandLevel _demand = InstagramDemandLevel.medium;
  bool _analyticsLoading = false;
  bool _analyticsHadError = false;
  AreaAnalyticsResult? _lastAnalytics;

  @override
  void initState() {
    super.initState();
    _areaCtrl.addListener(_onAreaTextChanged);
  }

  @override
  void dispose() {
    _areaDebounce?.cancel();
    _areaCtrl.removeListener(_onAreaTextChanged);
    _titleCtrl.dispose();
    _subtitleCtrl.dispose();
    _areaCtrl.dispose();
    _propertyTypeCtrl.dispose();
    _propertyIdCtrl.dispose();
    _dealsCtrl.dispose();
    super.dispose();
  }

  void _onAreaTextChanged() {
    _areaDebounce?.cancel();
    _areaDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      unawaited(_loadAreaAnalytics());
    });
  }

  Future<void> _loadAreaAnalytics() async {
    final area = _areaCtrl.text.trim();
    if (area.isEmpty) {
      setState(() {
        _analyticsLoading = false;
        _analyticsHadError = false;
        _lastAnalytics = null;
      });
      return;
    }

    setState(() {
      _analyticsLoading = true;
      _analyticsHadError = false;
    });

    try {
      final result = await _analytics.getAreaAnalytics(area);
      if (!mounted) return;
      setState(() {
        _analyticsLoading = false;
        _analyticsHadError = false;
        _lastAnalytics = result;
        _demand = result.instagramDemandLevel;
        _dealsCtrl.text = '${result.recentDeals}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _analyticsLoading = false;
        _analyticsHadError = true;
        _lastAnalytics = AreaAnalyticsService.kFallback;
        _demand = InstagramDemandLevel.medium;
        _dealsCtrl.text = '0';
      });
    }
  }

  String _demandLabel(AppLocalizations loc, String level) {
    switch (level) {
      case 'high':
        return loc.instagramDemandHigh;
      case 'low':
        return loc.instagramDemandLow;
      default:
        return loc.instagramDemandMedium;
    }
  }

  Widget _buildAnalyticsCard(AppLocalizations loc) {
    final area = _areaCtrl.text.trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  loc.instagramAreaAnalyticsHeadline,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: Colors.blueGrey.shade900,
                  ),
                ),
              ),
              if (area.isNotEmpty)
                TextButton.icon(
                  onPressed: _analyticsLoading ? null : () => _loadAreaAnalytics(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(loc.instagramAreaAnalyticsRefresh),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
          if (area.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              loc.instagramAreaAnalyticsEnterArea,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ] else if (_analyticsLoading) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    loc.instagramAreaAnalyticsLoading,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                ),
              ],
            ),
          ] else ...[
            if (_analyticsHadError) ...[
              const SizedBox(height: 8),
              Text(
                loc.instagramAreaAnalyticsError,
                style: TextStyle(fontSize: 12, color: Colors.red.shade800),
              ),
            ],
            if (_lastAnalytics != null) ...[
              const SizedBox(height: 8),
              Text(
                loc.instagramAreaAnalyticsDemand(
                  _demandLabel(loc, _lastAnalytics!.demandLevel),
                ),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade900),
              ),
              const SizedBox(height: 4),
              Text(
                loc.instagramAreaAnalyticsDeals(_lastAnalytics!.recentDeals),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade900),
              ),
            ],
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(loc.instagramPostDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              loc.instagramPostDialogHint,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleCtrl,
              decoration: InputDecoration(
                labelText: loc.instagramPostFieldTitle,
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _subtitleCtrl,
              decoration: InputDecoration(
                labelText: loc.instagramPostFieldSubtitle,
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _areaCtrl,
              decoration: InputDecoration(
                labelText: loc.instagramPostFieldArea,
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            _buildAnalyticsCard(loc),
            const SizedBox(height: 12),
            TextField(
              controller: _propertyTypeCtrl,
              decoration: InputDecoration(
                labelText: loc.instagramPostFieldPropertyType,
                border: const OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _propertyIdCtrl,
              decoration: InputDecoration(
                labelText: loc.instagramPostPropertyIdOptional,
                hintText: loc.instagramPostPropertyIdHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              loc.instagramDemandLevelLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            Text(
              loc.instagramDemandOverrideHint,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 6),
            SegmentedButton<InstagramDemandLevel>(
              segments: [
                ButtonSegment(
                  value: InstagramDemandLevel.high,
                  label: Text(loc.instagramDemandHigh),
                ),
                ButtonSegment(
                  value: InstagramDemandLevel.medium,
                  label: Text(loc.instagramDemandMedium),
                ),
                ButtonSegment(
                  value: InstagramDemandLevel.low,
                  label: Text(loc.instagramDemandLow),
                ),
              ],
              selected: {_demand},
              onSelectionChanged: (s) {
                setState(() => _demand = s.first);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dealsCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: loc.instagramRecentDealsLabel,
                hintText: loc.instagramRecentDealsHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.cancel),
        ),
        FilledButton.tonal(
          onPressed: () async {
            final t = _titleCtrl.text.trim();
            final area = _areaCtrl.text.trim();
            final pType = _propertyTypeCtrl.text.trim();
            if (t.isEmpty || area.isEmpty || pType.isEmpty) {
              ScaffoldMessenger.of(widget.navigatorContext).showSnackBar(
                SnackBar(content: Text(loc.instagramPostCarouselFillFields)),
              );
              return;
            }
            final deals = int.tryParse(_dealsCtrl.text.trim()) ?? 0;
            Navigator.pop(context);
            if (!widget.navigatorContext.mounted) return;
            await _runGenerateCarouselAndShowResult(
              widget.navigatorContext,
              title: t,
              area: area,
              propertyType: pType,
              propertyIdForTracking: _propertyIdCtrl.text.trim(),
              demandLevel: _demand,
              dealsCount: deals,
              isArabic: widget.isArabic,
            );
          },
          child: Text(loc.instagramPostGenerateCarousel),
        ),
        FilledButton(
          onPressed: () async {
            final t = _titleCtrl.text.trim();
            final s = _subtitleCtrl.text.trim();
            final area = _areaCtrl.text.trim();
            final pType = _propertyTypeCtrl.text.trim();
            if (t.isEmpty || s.isEmpty || area.isEmpty || pType.isEmpty) {
              ScaffoldMessenger.of(widget.navigatorContext).showSnackBar(
                SnackBar(content: Text(loc.instagramPostFillAllFields)),
              );
              return;
            }
            final deals = int.tryParse(_dealsCtrl.text.trim()) ?? 0;
            Navigator.pop(context);
            if (!widget.navigatorContext.mounted) return;
            await _runGenerateAndShowResult(
              widget.navigatorContext,
              title: t,
              subtitle: s,
              area: area,
              propertyType: pType,
              demandLevel: _demand,
              recentDealsCount: deals,
              isArabic: widget.isArabic,
            );
          },
          child: Text(loc.instagramPostGenerate),
        ),
      ],
    );
  }
}

Future<void> _runGenerateAndShowResult(
  BuildContext context, {
  required String title,
  required String subtitle,
  required String area,
  required String propertyType,
  required InstagramDemandLevel demandLevel,
  required int recentDealsCount,
  required bool isArabic,
}) async {
  final loc = AppLocalizations.of(context)!;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(loc.instagramPostGenerating)),
          ],
        ),
      ),
    ),
  );

  final url = await PostImageService.generateImage(title, subtitle);

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();

  if (url == null || url.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(loc.instagramPostFailed),
        backgroundColor: Colors.red.shade800,
      ),
    );
    return;
  }

  final caption = InstagramCaptionService.generateInstagramCaption(
    area: area,
    propertyType: propertyType,
    demandLevel: demandLevel,
    recentDealsCount: recentDealsCount,
    isArabic: isArabic,
  );

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(loc.instagramPostSuccessTitle),
      content: SingleChildScrollView(
        child: InstagramPostActionsWidget(
          imageUrl: url,
          caption: caption,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(loc.cancel),
        ),
      ],
    ),
  );
}

Future<void> _runGenerateCarouselAndShowResult(
  BuildContext context, {
  required String title,
  required String area,
  required String propertyType,
  required String propertyIdForTracking,
  required InstagramDemandLevel demandLevel,
  required int dealsCount,
  required bool isArabic,
}) async {
  final loc = AppLocalizations.of(context)!;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(loc.instagramPostGeneratingCarousel)),
          ],
        ),
      ),
    ),
  );

  final urls = await PostImageService.generateCarousel(
    title: title,
    area: area,
    propertyType: propertyType,
    demandLevel: demandLevel.name,
    dealsCount: dealsCount,
  );

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();

  if (urls.length < 4) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(loc.instagramPostCarouselFailed),
        backgroundColor: Colors.red.shade800,
      ),
    );
    return;
  }

  var ctrMap = <String, double>{};
  try {
    ctrMap = await CaptionPerformanceService().getHistoricalCtrByVariant();
  } catch (_) {}

  final learningWeights = await CaptionLearningService.getWeights();

  if (!context.mounted) return;

  final variants = CaptionVariantService.generateCaptionVariants(
    CaptionVariantInput(
      area: area,
      propertyType: propertyType,
      demandLevel: demandLevel,
      isArabic: isArabic,
      propertyId: propertyIdForTracking,
    ),
    historicalCtrByVariant: ctrMap,
    learningWeights: learningWeights,
  );

  final usageCtx = CaptionUsageContext(
    area: area,
    propertyType: propertyType,
    demandLevel: demandLevel.name,
    dealsCount: dealsCount,
  );

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(loc.instagramPostSuccessTitle),
      content: SingleChildScrollView(
        child: InstagramPostActionsWidget(
          imageUrls: urls,
          caption: variants.first.caption,
          rankedCaptionVariants: variants,
          captionUsageContext: usageCtx,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(loc.cancel),
        ),
      ],
    ),
  );

  if (!context.mounted) return;
  await showMarketingAutoDecisionDialog(
    context: context,
    area: area,
    propertyType: propertyType,
    dealsCount: dealsCount,
    demandLevel: demandLevel.name,
    isArabic: isArabic,
    propertyIdForTracking: propertyIdForTracking,
  );
}
