import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/services/ai_suggestions_auto_config_service.dart';
import 'package:aqarai_app/services/ai_suggestions_rollback_suggestion_service.dart';

/// Surfaces a heuristic “performance dropped after last update” hint with quick restore.
class AdminAiConfigRollbackBanner extends StatefulWidget {
  const AdminAiConfigRollbackBanner({super.key, required this.isAr});

  final bool isAr;

  @override
  State<AdminAiConfigRollbackBanner> createState() =>
      _AdminAiConfigRollbackBannerState();
}

class _AdminAiConfigRollbackBannerState extends State<AdminAiConfigRollbackBanner> {
  int? _dismissedForVersion;
  String? _busyRestoringDocId;

  bool get isAr => widget.isAr;

  Future<void> _confirmAndRestore(
    BuildContext context,
    AiConfigRollbackSuggestion hint,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'استعادة الإصدار السابق؟' : 'Restore previous version?'),
        content: Text(
          isAr
              ? 'سيتم استرجاع الإعداد من النسخة v${hint.previousVersion}.'
              : 'Restore AI config snapshot from v${hint.previousVersion}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isAr ? 'استعادة' : 'Restore'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    setState(() => _busyRestoringDocId = hint.previousHistoryDocId);
    try {
      await AiSuggestionsAutoConfigService.restoreConfigFromHistory(
        historyDocId: hint.previousHistoryDocId,
      );
      if (!context.mounted) return;
      setState(() => _dismissedForVersion = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr
                ? 'تمت الاستعادة إلى v${hint.previousVersion}.'
                : 'Restored to v${hint.previousVersion}.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isAr ? 'فشلت الاستعادة: $e' : 'Restore failed: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _busyRestoringDocId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AiSuggestionsAutoConfig>(
      stream: AiSuggestionsAutoConfigService.watch(),
      builder: (context, snap) {
        final cfg = snap.data;
        if (cfg == null) {
          return snap.hasError
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    isAr ? 'تعذر تحميل الإعداد' : 'Config load error',
                    style: TextStyle(color: Colors.red.shade800),
                  ),
                )
              : const SizedBox.shrink();
        }

        if (_dismissedForVersion == cfg.configVersion) {
          return const SizedBox.shrink();
        }

        return _RollbackEvalBody(
          cfg: cfg,
          isAr: isAr,
          busyRestoringDocId: _busyRestoringDocId,
          onDismiss: () => setState(() => _dismissedForVersion = cfg.configVersion),
          onRestore: (hint) => _confirmAndRestore(context, hint),
        );
      },
    );
  }
}

class _RollbackEvalBody extends StatefulWidget {
  const _RollbackEvalBody({
    required this.cfg,
    required this.isAr,
    required this.busyRestoringDocId,
    required this.onDismiss,
    required this.onRestore,
  });

  final AiSuggestionsAutoConfig cfg;
  final bool isAr;
  final String? busyRestoringDocId;
  final VoidCallback onDismiss;
  final void Function(AiConfigRollbackSuggestion hint) onRestore;

  @override
  State<_RollbackEvalBody> createState() => _RollbackEvalBodyState();
}

class _RollbackEvalBodyState extends State<_RollbackEvalBody> {
  static String _pct(double? x) {
    if (x == null) return '—';
    return '${(x * 100).toStringAsFixed(1)}%';
  }

  late Future<AiConfigRollbackSuggestion?> _future;

  @override
  void initState() {
    super.initState();
    _future = AiSuggestionsRollbackSuggestionService.evaluate(widget.cfg);
  }

  @override
  void didUpdateWidget(_RollbackEvalBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cfg.configVersion != widget.cfg.configVersion ||
        oldWidget.cfg.updatedAt != widget.cfg.updatedAt) {
      _future = AiSuggestionsRollbackSuggestionService.evaluate(widget.cfg);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AiConfigRollbackSuggestion?>(
      future: _future,
      builder: (context, hintSnap) {
        if (hintSnap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        final hint = hintSnap.data;
        if (hint == null) return const SizedBox.shrink();

        final busy = widget.busyRestoringDocId == hint.previousHistoryDocId;
        final isAr = widget.isAr;
        final ctrLine = isAr
            ? 'CTR: ${_pct(hint.ctrBefore)} ← ${_pct(hint.ctrAfter)}'
            : 'CTR: ${_pct(hint.ctrBefore)} → ${_pct(hint.ctrAfter)}';
        final convLine = isAr
            ? 'التحويل: ${_pct(hint.convBefore)} ← ${_pct(hint.convAfter)}'
            : 'Conversion: ${_pct(hint.convBefore)} → ${_pct(hint.convAfter)}';

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Material(
            color: const Color(0xFFFFF4E5),
            elevation: 0,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2B46C)),
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Colors.orange.shade800, size: 26),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isAr
                                  ? 'انخفاض الأداء بعد آخر تحديث (v${hint.currentVersion}). استعادة النسخة السابقة؟'
                                  : 'Performance dropped after the last update (v${hint.currentVersion}). Restore the previous version?',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: AppColors.navy,
                                fontSize: 14,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              ctrLine,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              convLine,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade900,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () => widget.onRestore(hint),
                        icon: busy
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                              )
                            : const Icon(Icons.settings_backup_restore, size: 18),
                        label: Text(
                          isAr
                              ? 'استعادة v${hint.previousVersion}'
                              : 'Restore v${hint.previousVersion}',
                        ),
                      ),
                      TextButton(
                        onPressed: widget.onDismiss,
                        child: Text(isAr ? 'تجاهل' : 'Dismiss'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
