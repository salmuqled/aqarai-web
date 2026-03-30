import 'package:flutter/material.dart';

import 'package:aqarai_app/config/auto_mode_config.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/services/hybrid_marketing_settings_service.dart';

Future<void> showHybridMarketingSettingsDialog({
  required BuildContext context,
}) async {
  final initial = await HybridMarketingSettingsService.load();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => _HybridMarketingSettingsBody(initial: initial),
  );
}

class _HybridMarketingSettingsBody extends StatefulWidget {
  const _HybridMarketingSettingsBody({
    required this.initial,
  });

  final HybridMarketingSettings initial;

  @override
  State<_HybridMarketingSettingsBody> createState() =>
      _HybridMarketingSettingsBodyState();
}

class _HybridMarketingSettingsBodyState
    extends State<_HybridMarketingSettingsBody> {
  late bool _autoExec;
  late double _autoTh;
  late double _reviewTh;

  @override
  void initState() {
    super.initState();
    _autoExec = widget.initial.autoExecutionEnabled;
    _autoTh = widget.initial.autoThreshold;
    _reviewTh = widget.initial.reviewThreshold;
  }

  void _normalizeReview() {
    if (_reviewTh >= _autoTh) {
      _reviewTh = (_autoTh - 0.05).clamp(
        AutoModeConfig.reviewThresholdMin,
        _autoTh - 0.01,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(loc.hybridSettingsTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(loc.hybridSettingsAutoExec),
              value: _autoExec,
              onChanged: (v) => setState(() => _autoExec = v),
            ),
            const SizedBox(height: 12),
            Text(loc.hybridSettingsAutoThreshold),
            Slider(
              value: _autoTh,
              min: AutoModeConfig.autoThresholdMin,
              max: AutoModeConfig.autoThresholdMax,
              divisions: 15,
              label: _autoTh.toStringAsFixed(2),
              onChanged: (v) {
                setState(() {
                  _autoTh = v;
                  _normalizeReview();
                });
              },
            ),
            Text(loc.hybridSettingsReviewThreshold),
            Slider(
              value: _reviewTh,
              min: AutoModeConfig.reviewThresholdMin,
              max: AutoModeConfig.reviewThresholdMax,
              divisions: 25,
              label: _reviewTh.toStringAsFixed(2),
              onChanged: (v) {
                setState(() {
                  _reviewTh = v;
                  if (_reviewTh >= _autoTh) {
                    _reviewTh = (_autoTh - 0.05).clamp(
                      AutoModeConfig.reviewThresholdMin,
                      _autoTh - 0.01,
                    );
                  }
                });
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.cancel),
        ),
        FilledButton(
          onPressed: () async {
            await HybridMarketingSettingsService.save(
              HybridMarketingSettings(
                autoExecutionEnabled: _autoExec,
                autoThreshold: _autoTh,
                reviewThreshold: _reviewTh,
              ),
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(loc.hybridSettingsSave),
        ),
      ],
    );
  }
}
