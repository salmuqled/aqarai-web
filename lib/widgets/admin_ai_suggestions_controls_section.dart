import 'dart:async';

import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/services/ai_suggestions_auto_config_service.dart';

/// Admin controls for [analytics/ai_suggestions_config] — live via Firestore snapshots.
class AdminAiSuggestionsControlsSection extends StatefulWidget {
  const AdminAiSuggestionsControlsSection({super.key, required this.isAr});

  final bool isAr;

  @override
  State<AdminAiSuggestionsControlsSection> createState() =>
      _AdminAiSuggestionsControlsSectionState();
}

class _AdminAiSuggestionsControlsSectionState
    extends State<AdminAiSuggestionsControlsSection> {
  Timer? _relativeClock;

  @override
  void initState() {
    super.initState();
    _relativeClock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _relativeClock?.cancel();
    super.dispose();
  }

  bool get isAr => widget.isAr;

  static int _planForDropdown(int raw) {
    const opts = [3, 7, 14, 30];
    if (opts.contains(raw)) return raw;
    return 30;
  }

  static String _relativeUpdated(DateTime? t, bool isAr) {
    if (t == null) return isAr ? 'لا يوجد' : 'Never';
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 45) return isAr ? 'الآن' : 'Just now';
    if (diff.inMinutes < 60) {
      final m = diff.inMinutes;
      return isAr ? 'منذ $m د' : '$m min ago';
    }
    if (diff.inHours < 48) {
      final h = diff.inHours;
      return isAr ? 'منذ $h س' : '${h}h ago';
    }
    final d = diff.inDays;
    return isAr ? 'منذ $d يوم' : '${d}d ago';
  }

  static String _changedByLabel(String? id, bool isAr) {
    if (id == null || id.isEmpty) return isAr ? '—' : '—';
    if (id == AiSuggestionsAutoConfig.updatedBySystemAutoTune) {
      return isAr ? 'النظام (ضبط تلقائي)' : 'System (auto-tune)';
    }
    return isAr ? 'مسؤول' : 'Admin';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AiSuggestionsAutoConfig>(
      stream: AiSuggestionsAutoConfigService.watch(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.red.shade200),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                isAr
                    ? 'تعذر تحميل إعدادات AI: ${snap.error}'
                    : 'Could not load AI config: ${snap.error}',
                style: TextStyle(color: Colors.red.shade800),
              ),
            ),
          );
        }

        final cfg = snap.data ?? AiSuggestionsAutoConfig.defaults;
        final planValue = _planForDropdown(cfg.defaultPlanDays);

        Future<void> patch(Future<void> Function() fn) async {
          try {
            await fn();
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  isAr ? 'فشل الحفظ: $e' : 'Save failed: $e',
                ),
                backgroundColor: Colors.red,
              ),
            );
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isAr ? 'التحكم بالذكاء الاصطناعي' : 'AI Controls',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.navy,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isAr
                  ? 'analytics/ai_suggestions_config — التغييرات تطبّق فوراً في التطبيق.'
                  : 'analytics/ai_suggestions_config — changes apply live in the app.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            Card(
              elevation: 0,
              color: Colors.blueGrey.shade50,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: Colors.grey.shade300),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.history, size: 20, color: Colors.grey.shade800),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isAr
                                    ? 'آخر تحديث: ${_relativeUpdated(cfg.updatedAt, isAr)}'
                                    : 'Last updated: ${_relativeUpdated(cfg.updatedAt, isAr)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.grey.shade900,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Builder(
                                builder: (context) {
                                  final line = isAr
                                      ? 'تم التغيير بواسطة: ${_changedByLabel(cfg.updatedBy, isAr)}'
                                      : 'Changed by: ${_changedByLabel(cfg.updatedBy, isAr)}';
                                  final id = cfg.updatedBy;
                                  if (id != null && id.isNotEmpty) {
                                    return Tooltip(
                                      message: id,
                                      child: Text(
                                        line,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.grey.shade800,
                                        ),
                                      ),
                                    );
                                  }
                                  return Text(
                                    line,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade800,
                                    ),
                                  );
                                },
                              ),
                              if (cfg.changeSummary != null &&
                                  cfg.changeSummary!.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  isAr ? 'ملخص التغيير:' : 'Last change:',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                SelectableText(
                                  cfg.changeSummary!,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.35,
                                    color: Colors.grey.shade900,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(isAr ? 'تفعيل AI للاقتراحات' : 'AI enabled'),
                      subtitle: Text(
                        isAr
                            ? 'عند الإيقاف، يُتجاهل كل إعداد تلقائي في الواجهة.'
                            : 'When off, the app ignores AI config and uses defaults.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      ),
                      value: cfg.aiEnabled,
                      onChanged: (v) => patch(
                        () => AiSuggestionsAutoConfigService.patchConfig(
                          aiEnabled: v,
                        ),
                      ),
                    ),
                    const Divider(height: 24),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        isAr ? 'التحسين التلقائي' : 'Auto optimization',
                      ),
                      subtitle: Text(
                        isAr
                            ? 'عند الإيقاف، لن يعدل الجدول اليومي الإعدادات (يدوي فقط).'
                            : 'When off, the daily scheduler will not change this config.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      ),
                      value: !cfg.manualOverride,
                      onChanged: (v) => patch(
                        () => AiSuggestionsAutoConfigService.patchConfig(
                          manualOverride: !v,
                        ),
                      ),
                    ),
                    const Divider(height: 24),
                    Text(
                      isAr ? 'مضاعف الظهور' : 'Exposure multiplier',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.navy,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isAr ? 'من ٠٫٥ إلى ٢٫٠' : '0.5 → 2.0',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    _ExposureSlider(
                      key: ValueKey(
                        '${cfg.configVersion}_${cfg.exposureMultiplier}',
                      ),
                      serverValue: cfg.exposureMultiplier,
                      isAr: isAr,
                      onCommit: (v) => AiSuggestionsAutoConfigService.patchConfig(
                        exposureMultiplier: v,
                      ),
                    ),
                    const Divider(height: 24),
                    Text(
                      isAr ? 'الخطة الافتراضية' : 'Default plan (days)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.navy,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            value: planValue,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 3, child: Text('3')),
                              DropdownMenuItem(value: 7, child: Text('7')),
                              DropdownMenuItem(value: 14, child: Text('14')),
                              DropdownMenuItem(value: 30, child: Text('30')),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              patch(
                                () => AiSuggestionsAutoConfigService.patchConfig(
                                  defaultPlanDays: v,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ExposureSlider extends StatefulWidget {
  const _ExposureSlider({
    super.key,
    required this.serverValue,
    required this.isAr,
    required this.onCommit,
  });

  final double serverValue;
  final bool isAr;
  final Future<void> Function(double) onCommit;

  @override
  State<_ExposureSlider> createState() => _ExposureSliderState();
}

class _ExposureSliderState extends State<_ExposureSlider> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.serverValue.clamp(0.5, 2.0);
  }

  @override
  void didUpdateWidget(covariant _ExposureSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverValue != widget.serverValue) {
      _value = widget.serverValue.clamp(0.5, 2.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Slider(
          min: 0.5,
          max: 2.0,
          divisions: 30,
          value: _value.clamp(0.5, 2.0),
          label: _value.toStringAsFixed(2),
          onChanged: (v) => setState(() => _value = v),
          onChangeEnd: (v) async {
            final clamped = v.clamp(0.5, 2.0);
            try {
              await widget.onCommit(clamped);
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      widget.isAr ? 'فشل حفظ المضاعف' : 'Failed to save multiplier',
                    ),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }
          },
        ),
        Text(
          widget.isAr
              ? 'القيمة الحالية: ${_value.toStringAsFixed(2)}'
              : 'Current: ${_value.toStringAsFixed(2)}',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
        ),
      ],
    );
  }
}
