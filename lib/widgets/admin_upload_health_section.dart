import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/services/system_alerts_service.dart';
import 'package:aqarai_app/services/upload_health_service.dart';

enum _UploadHealthWindow { h24, d7 }

/// Admin metrics from Firestore [upload_events] (property image pipeline).
class AdminUploadHealthSection extends StatefulWidget {
  const AdminUploadHealthSection({super.key});

  @override
  State<AdminUploadHealthSection> createState() => _AdminUploadHealthSectionState();
}

class _AdminUploadHealthSectionState extends State<AdminUploadHealthSection> {
  _UploadHealthWindow _window = _UploadHealthWindow.d7;

  /// Cached so parent rebuilds (scroll / streams) do not restart [UploadHealthService.load] every frame.
  late Future<UploadHealthSnapshot> _healthFuture;

  /// Avoid duplicate [system_alerts] rows for the same snapshot + window.
  String? _lastLoggedIssueDedupeKey;

  /// In-flight log key (mutation outside [setState] is intentional to dedupe in [build]).
  String? _ongoingLogDedupeKey;

  Duration _dur(_UploadHealthWindow w) {
    switch (w) {
      case _UploadHealthWindow.h24:
        return const Duration(hours: 24);
      case _UploadHealthWindow.d7:
        return const Duration(days: 7);
    }
  }

  String _windowLabel(BuildContext context, _UploadHealthWindow w) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    switch (w) {
      case _UploadHealthWindow.h24:
        return isAr ? 'آخر ٢٤ ساعة' : 'Last 24h';
      case _UploadHealthWindow.d7:
        return isAr ? 'آخر ٧ أيام' : 'Last 7 days';
    }
  }

  static String _pct(double? r) {
    if (r == null) return '—';
    return '${(r * 100).clamp(0, 999).toStringAsFixed(1)}%';
  }

  @override
  void initState() {
    super.initState();
    _healthFuture = UploadHealthService.load(window: _dur(_window));
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    Widget metricRow({
      required String label,
      required String value,
      required IconData icon,
      Color? valueColor,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppColors.navy),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: valueColor ?? AppColors.navy,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                isAr ? 'صحة رفع الصور' : 'Upload Health',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.navy,
                ),
              ),
            ),
            DropdownButton<_UploadHealthWindow>(
              value: _window,
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _window = v;
                  _lastLoggedIssueDedupeKey = null;
                  _healthFuture = UploadHealthService.load(window: _dur(_window));
                });
              },
              items: _UploadHealthWindow.values
                  .map(
                    (w) => DropdownMenuItem<_UploadHealthWindow>(
                      value: w,
                      child: Text(_windowLabel(context, w)),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          isAr
              ? 'المصدر: upload_events (بدء / نجاح / فشل / إعادة محاولة).'
              : 'Source: upload_events (started / success / failed / retry).',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        FutureBuilder<UploadHealthSnapshot>(
          future: _healthFuture,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: CircularProgressIndicator(),
                ),
              );
            }
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
                        ? 'تعذر تحميل صحة الرفع: ${snap.error}'
                        : 'Failed to load upload health: ${snap.error}',
                    style: TextStyle(color: Colors.red.shade800),
                  ),
                ),
              );
            }

            final d = snap.data!;

            if (d.hasReliabilityIssue) {
              final dedupeKey =
                  '${_window.name}_${d.totalStarted}_${d.totalSuccess}_${d.totalFailed}_${d.totalRetry}';
              if (_lastLoggedIssueDedupeKey != dedupeKey &&
                  _ongoingLogDedupeKey != dedupeKey) {
                _ongoingLogDedupeKey = dedupeKey;
                final windowLabel = _windowLabel(context, _window);
                SystemAlertsService.logUploadReliabilityIssue(
                  snapshot: d,
                  windowLabel: windowLabel,
                ).then((ok) {
                  _ongoingLogDedupeKey = null;
                  if (!mounted) return;
                  if (ok) setState(() => _lastLoggedIssueDedupeKey = dedupeKey);
                });
              }
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (d.hasReliabilityIssue) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.red.shade600,
                          Colors.deepOrange.shade600,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.orange.withValues(alpha: 0.35),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            color: Colors.white, size: 28),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isAr
                                    ? 'تم رصد مشكلة في موثوقية رفع الصور'
                                    : 'Upload reliability issue detected',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  height: 1.25,
                                ),
                              ),
                              if (d.reliabilityBreachTags.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  d.reliabilityBreachTags.join(' · '),
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.92),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isAr
                          ? 'الأحداث: بدء ${d.totalStarted} · نجاح ${d.totalSuccess} · فشل ${d.totalFailed} · إعادة ${d.totalRetry}'
                          : 'Events: started ${d.totalStarted} · success ${d.totalSuccess} · failed ${d.totalFailed} · retry ${d.totalRetry}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const Divider(height: 24),
                    metricRow(
                      label: isAr ? 'معدل النجاح (نجاح ÷ بدء)' : 'Success rate (success ÷ started)',
                      value: _pct(d.successRate),
                      icon: Icons.check_circle_outline,
                      valueColor: Colors.green.shade800,
                    ),
                    metricRow(
                      label: isAr ? 'معدل الفشل (فشل ÷ بدء)' : 'Failure rate (failed ÷ started)',
                      value: _pct(d.failureRate),
                      icon: Icons.error_outline,
                      valueColor: Colors.red.shade800,
                    ),
                    metricRow(
                      label: isAr ? 'معدل إعادة المحاولة (إعادة ÷ بدء)' : 'Retry rate (retry ÷ started)',
                      value: _pct(d.retryRate),
                      icon: Icons.refresh,
                      valueColor: Colors.orange.shade900,
                    ),
                    if (d.totalStarted == 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          isAr
                              ? 'لا توجد أحداث «بدء» في هذه النافذة — المعدلات غير معرّفة.'
                              : 'No "started" events in this window — rates undefined.',
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: Colors.grey.shade600,
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
        ),
      ],
    );
  }
}
