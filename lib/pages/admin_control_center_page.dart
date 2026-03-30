import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/config/auto_mode_config.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auto_decision_trust.dart';
import 'package:aqarai_app/models/decision_accuracy_snapshot.dart';
import 'package:aqarai_app/models/hybrid_marketing_settings.dart';
import 'package:aqarai_app/models/system_alert.dart';
import 'package:aqarai_app/services/admin_control_center_service.dart';
import 'package:aqarai_app/services/admin_settings_service.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/system_alerts_service.dart';
import 'package:aqarai_app/widgets/admin_system_alerts_section.dart';

/// Admin hub: hybrid marketing status, trust, notification performance, and controls.
class AdminControlCenterPage extends StatefulWidget {
  const AdminControlCenterPage({super.key});

  @override
  State<AdminControlCenterPage> createState() => _AdminControlCenterPageState();
}

class _AdminControlCenterPageState extends State<AdminControlCenterPage> {
  Future<bool> _adminGateFuture = AuthService.isAdmin();

  Future<void> _persistHybrid(HybridMarketingSettings h) async {
    await AdminSettingsService.saveSettings(h);
    if (!mounted) return;
    final loc = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(loc.adminControlCenterSaved)),
    );
  }

  void _retryAdminGate() {
    setState(() => _adminGateFuture = AuthService.isAdmin());
  }

  Future<void> _confirmResetLearning() async {
    final loc = AppLocalizations.of(context)!;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.adminControlCenterResetLearningTitle),
        content: Text(loc.adminControlCenterResetLearningBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.adminControlCenterResetLearning),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    try {
      await AdminControlCenterService.resetLearningState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.adminControlCenterDone)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.adminControlCenterFailed)),
      );
    }
  }

  Future<void> _disableShield() async {
    final loc = AppLocalizations.of(context)!;
    try {
      await AdminControlCenterService.disableShieldManually();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.adminControlCenterDone)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.adminControlCenterFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return FutureBuilder<bool>(
      future: _adminGateFuture,
      builder: (context, adminSnap) {
        if (adminSnap.connectionState == ConnectionState.waiting) {
          return Scaffold(
            backgroundColor: const Color(0xFFF7F7F7),
            appBar: AppBar(title: Text(loc.adminControlCenterTitle)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (adminSnap.data != true) {
          return Scaffold(
            backgroundColor: const Color(0xFFF7F7F7),
            appBar: AppBar(title: Text(loc.adminControlCenterTitle)),
            body: _AccessDenied(isAr: isAr, onRetry: _retryAdminGate),
          );
        }
        return StreamBuilder<List<SystemAlert>>(
          stream: SystemAlertsService.watchAlerts(),
          builder: (context, alertSnap) {
            final alerts = alertSnap.data ?? [];
            final unreadAlerts = alerts.where((a) => !a.read).length;

            return StreamBuilder<HybridMarketingSettings>(
              stream: AdminSettingsService.watchSettings(),
              builder: (context, hybridSnap) {
                final hybrid =
                    hybridSnap.data ?? HybridMarketingSettings.defaults;

                return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: AdminControlCenterService.watchLearningState(),
                  builder: (context, stateSnap) {
                    final raw = stateSnap.data?.data();
                    final accuracy = DecisionAccuracySnapshot.fromStateMap(raw);
                    final trust = AutoDecisionTrust.fromStateMap(raw);

                    return Scaffold(
                      backgroundColor: const Color(0xFFF7F7F7),
                      appBar: AppBar(
                        title: Text(loc.adminControlCenterTitle),
                        centerTitle: true,
                        actions: [
                          if (unreadAlerts > 0)
                            Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: Badge(
                                label: Text('$unreadAlerts'),
                                child: const Icon(
                                  Icons.notifications_active_outlined,
                                ),
                              ),
                            ),
                        ],
                      ),
                      body: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AdminSystemAlertsSection(
                              loc: loc,
                              isAr: isAr,
                              alerts: alerts,
                              streamError: alertSnap.hasError,
                            ),
                            const SizedBox(height: 18),
                            if (hybridSnap.hasError)
                              _ErrorBanner(
                                message: isAr
                                    ? 'تعذّر تحميل إعدادات التسويق.'
                                    : 'Could not load marketing settings.',
                              ),
                            if (stateSnap.hasError)
                              _ErrorBanner(
                                message: isAr
                                    ? 'تعذّر تحميل حالة التعلّم.'
                                    : 'Could not load learning state.',
                              ),
                            _SectionTitle(text: loc.adminControlCenterSystemStatus),
                        _SystemStatusGrid(
                          loc: loc,
                          hybrid: hybrid,
                          accuracy: accuracy,
                          trustAverage: trust.averageTrust,
                        ),
                        _SectionTitle(text: loc.adminControlCenterTrust),
                        _TrustSection(loc: loc, trust: trust),
                        _SectionTitle(text: loc.adminControlCenterPerformance),
                        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                          stream: AdminControlCenterService
                              .watchNotificationLogsForPerformance(),
                          builder: (context, perfSnap) {
                            if (perfSnap.hasError) {
                              return _ErrorBanner(
                                message: isAr
                                    ? 'تعذّر تحميل سجلات الإشعارات.'
                                    : 'Could not load notification logs.',
                              );
                            }
                            final docs = perfSnap.data?.docs ?? const [];
                            final agg = _aggregateNotificationLogs(docs);
                            return _PerformanceSection(loc: loc, agg: agg);
                          },
                        ),
                        _SectionTitle(text: loc.adminControlCenterControls),
                            _ControlsSection(
                              loc: loc,
                              hybrid: hybrid,
                              onChanged: _persistHybrid,
                              onResetLearning: _confirmResetLearning,
                              onDisableShield: _disableShield,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _AccessDenied extends StatelessWidget {
  const _AccessDenied({required this.isAr, required this.onRetry});

  final bool isAr;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 48, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            Text(
              isAr ? 'غير مصرّح.' : 'Not authorized.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(isAr ? 'إعادة' : 'Retry')),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: Colors.red.shade800),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: Colors.red.shade900, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w800,
          color: Colors.blueGrey.shade900,
        ),
      ),
    );
  }
}

class _SystemStatusGrid extends StatelessWidget {
  const _SystemStatusGrid({
    required this.loc,
    required this.hybrid,
    required this.accuracy,
    required this.trustAverage,
  });

  final AppLocalizations loc;
  final HybridMarketingSettings hybrid;
  final DecisionAccuracySnapshot accuracy;
  final double trustAverage;

  @override
  Widget build(BuildContext context) {
    final autoOn = hybrid.autoExecutionEnabled;
    final autoLabel =
        autoOn ? loc.adminControlCenterAutoModeOn : loc.adminControlCenterAutoModeOff;
    final shieldLabel = accuracy.autoShieldEnabled
        ? loc.adminControlCenterShieldActive
        : loc.adminControlCenterShieldInactive;
    final trustPct = (trustAverage * 100).clamp(0, 100).toStringAsFixed(0);
    final deltaStr = accuracy.outcomeLearningDeltaPct != null
        ? '${accuracy.outcomeLearningDeltaPct! >= 0 ? '+' : ''}${accuracy.outcomeLearningDeltaPct!.toStringAsFixed(1)} pp'
        : loc.adminControlCenterLastDeltaNone;

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.45,
      children: [
        _StatusCard(
          icon: Icons.bolt_outlined,
          iconColor: autoOn ? Colors.green.shade700 : Colors.grey.shade600,
          title: autoLabel,
        ),
        _StatusCard(
          icon: Icons.shield_outlined,
          iconColor:
              accuracy.autoShieldEnabled ? Colors.deepOrange.shade800 : Colors.blueGrey,
          title: shieldLabel,
        ),
        _StatusCard(
          icon: Icons.psychology_outlined,
          iconColor: AppColors.navy,
          title: '${loc.adminControlCenterAvgTrust}\n$trustPct%',
        ),
        _StatusCard(
          icon: Icons.trending_flat,
          iconColor: Colors.indigo.shade700,
          title: '${loc.adminControlCenterLastDelta}\n$deltaStr',
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.iconColor,
    required this.title,
  });

  final IconData icon;
  final Color iconColor;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: iconColor, size: 26),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.25,
                color: Colors.blueGrey.shade900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double _normTrustBar(double t) => ((t - 0.5) / 0.5).clamp(0.0, 1.0);

class _TrustSection extends StatelessWidget {
  const _TrustSection({required this.loc, required this.trust});

  final AppLocalizations loc;
  final AutoDecisionTrust trust;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TrustRow(
              label: loc.adminDecisionTrustCaptionLine(
                (trust.captionTrust * 100).toStringAsFixed(0),
              ),
              value: trust.captionTrust,
            ),
            const SizedBox(height: 14),
            _TrustRow(
              label: loc.adminDecisionTrustTimeLine(
                (trust.timeTrust * 100).toStringAsFixed(0),
              ),
              value: trust.timeTrust,
            ),
            const SizedBox(height: 14),
            _TrustRow(
              label: loc.adminDecisionTrustAudienceLine(
                (trust.audienceTrust * 100).toStringAsFixed(0),
              ),
              value: trust.audienceTrust,
            ),
          ],
        ),
      ),
    );
  }
}

class _TrustRow extends StatelessWidget {
  const _TrustRow({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.blueGrey.shade900,
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: _normTrustBar(value),
            minHeight: 10,
            backgroundColor: Colors.grey.shade200,
            color: AppColors.navy,
          ),
        ),
      ],
    );
  }
}

class _NotifPerfAgg {
  _NotifPerfAgg({
    required this.points,
    required this.totalConversions,
    required this.bestVariant,
    required this.bestCtr,
  });

  final List<_CtrPoint> points;
  final int totalConversions;
  final String bestVariant;
  final double bestCtr;
}

class _CtrPoint {
  _CtrPoint(this.label, this.ctrPct);

  final String label;
  final double ctrPct;
}

_NotifPerfAgg _aggregateNotificationLogs(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> docsNewestFirst,
) {
  int ni(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse('$v') ?? 0;
  }

  if (docsNewestFirst.isEmpty) {
    return _NotifPerfAgg(
      points: const [],
      totalConversions: 0,
      bestVariant: '—',
      bestCtr: 0,
    );
  }

  final chrono = docsNewestFirst.reversed.toList();
  final points = <_CtrPoint>[];
  for (final d in chrono) {
    final m = d.data();
    final sent = ni(m['sentCount']);
    final clicks = ni(m['clickCount']);
    final ctrPct = sent > 0 ? (clicks / sent) * 100.0 : 0.0;
    var label = '·';
    final ts = m['createdAt'];
    if (ts is Timestamp) {
      final dt = ts.toDate();
      label = '${dt.month}/${dt.day}';
    }
    points.add(_CtrPoint(label, ctrPct));
  }

  var totalConv = 0;
  var bestCtr = -1.0;
  var bestVar = '—';
  for (final d in docsNewestFirst) {
    final m = d.data();
    totalConv += ni(m['conversionCount']);
    final sent = ni(m['sentCount']);
    final clicks = ni(m['clickCount']);
    if (sent <= 0) continue;
    final ctr = clicks / sent;
    if (ctr > bestCtr) {
      bestCtr = ctr;
      final vid = m['variantId']?.toString().trim() ?? '';
      final cid = m['chosenCaptionId']?.toString().trim() ?? '';
      bestVar = vid.isNotEmpty ? vid : (cid.isNotEmpty ? cid : 'A');
    }
  }
  if (bestCtr < 0) bestCtr = 0;

  return _NotifPerfAgg(
    points: points,
    totalConversions: totalConv,
    bestVariant: bestVar,
    bestCtr: bestCtr,
  );
}

class _PerformanceSection extends StatelessWidget {
  const _PerformanceSection({required this.loc, required this.agg});

  final AppLocalizations loc;
  final _NotifPerfAgg agg;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              loc.adminControlCenterCtrTrend,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: Colors.blueGrey.shade900,
              ),
            ),
            const SizedBox(height: 12),
            if (agg.points.isEmpty)
              Text(
                loc.adminControlCenterNoPerformanceData,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              )
            else
              SizedBox(
                height: 200,
                child: _CtrLineChart(points: agg.points),
              ),
            const SizedBox(height: 16),
            Text(
              '${loc.adminControlCenterTotalConversions}: ${agg.totalConversions}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.blueGrey.shade900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              loc.adminControlCenterBestCaption,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: Colors.blueGrey.shade800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              loc.adminControlCenterBestCaptionValue(
                agg.bestVariant,
                '${(agg.bestCtr * 100).toStringAsFixed(1)}%',
              ),
              style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
            ),
          ],
        ),
      ),
    );
  }
}

class _CtrLineChart extends StatelessWidget {
  const _CtrLineChart({required this.points});

  final List<_CtrPoint> points;

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (var i = 0; i < points.length; i++) {
      spots.add(FlSpot(i.toDouble(), points[i].ctrPct));
    }
    final maxYRaw =
        points.map((p) => p.ctrPct).fold<double>(0, math.max);
    final maxY = math.max(maxYRaw * 1.15, 4.0);
    final labelEvery = points.length > 12 ? (points.length / 6).ceil() : 1;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: points.length <= 1 ? 1 : (points.length - 1).toDouble(),
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY > 10 ? maxY / 5 : 2,
          getDrawingHorizontalLine: (v) =>
              FlLine(color: Colors.grey.shade200, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              interval: maxY > 10 ? maxY / 5 : 2,
              getTitlesWidget: (v, m) => Text(
                v.round().toString(),
                style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: 1,
              getTitlesWidget: (v, m) {
                final i = v.round();
                if (i < 0 || i >= points.length) {
                  return const SizedBox.shrink();
                }
                if (i % labelEvery != 0 && i != points.length - 1) {
                  return const SizedBox.shrink();
                }
                final lb = points[i].label;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    lb,
                    style: TextStyle(fontSize: 9, color: Colors.grey.shade700),
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: AppColors.navy,
            barWidth: 2.5,
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: AppColors.navy.withValues(alpha: 0.07),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touched) {
              final out = <LineTooltipItem>[];
              for (final t in touched) {
                final i = t.x.round();
                if (i < 0 || i >= points.length) continue;
                final p = points[i];
                out.add(
                  LineTooltipItem(
                    '${p.label}\n${p.ctrPct.toStringAsFixed(2)}%',
                    const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                );
              }
              return out;
            },
          ),
        ),
      ),
    );
  }
}

class _ControlsSection extends StatelessWidget {
  const _ControlsSection({
    required this.loc,
    required this.hybrid,
    required this.onChanged,
    required this.onResetLearning,
    required this.onDisableShield,
  });

  final AppLocalizations loc;
  final HybridMarketingSettings hybrid;
  final Future<void> Function(HybridMarketingSettings) onChanged;
  final VoidCallback onResetLearning;
  final VoidCallback onDisableShield;

  @override
  Widget build(BuildContext context) {
    return _ControlsBody(
      loc: loc,
      initial: hybrid,
      onChanged: onChanged,
      onResetLearning: onResetLearning,
      onDisableShield: onDisableShield,
    );
  }
}

class _ControlsBody extends StatefulWidget {
  const _ControlsBody({
    required this.loc,
    required this.initial,
    required this.onChanged,
    required this.onResetLearning,
    required this.onDisableShield,
  });

  final AppLocalizations loc;
  final HybridMarketingSettings initial;
  final Future<void> Function(HybridMarketingSettings) onChanged;
  final VoidCallback onResetLearning;
  final VoidCallback onDisableShield;

  @override
  State<_ControlsBody> createState() => _ControlsBodyState();
}

class _ControlsBodyState extends State<_ControlsBody> {
  late bool _autoExec;
  late double _autoTh;
  late double _reviewTh;

  @override
  void initState() {
    super.initState();
    _syncFrom(widget.initial);
  }

  @override
  void didUpdateWidget(covariant _ControlsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final o = oldWidget.initial;
    final n = widget.initial;
    if (o.autoExecutionEnabled != n.autoExecutionEnabled ||
        (o.autoThreshold - n.autoThreshold).abs() > 1e-9 ||
        (o.reviewThreshold - n.reviewThreshold).abs() > 1e-9) {
      _syncFrom(n);
    }
  }

  void _syncFrom(HybridMarketingSettings h) {
    _autoExec = h.autoExecutionEnabled;
    _autoTh = h.autoThreshold;
    _reviewTh = h.reviewThreshold;
  }

  void _normalizeReview() {
    if (_reviewTh >= _autoTh) {
      _reviewTh = (_autoTh - 0.05).clamp(
        AutoModeConfig.reviewThresholdMin,
        _autoTh - 0.01,
      );
    }
  }

  HybridMarketingSettings _currentSettings() => HybridMarketingSettings(
        autoExecutionEnabled: _autoExec,
        autoThreshold: _autoTh,
        reviewThreshold: _reviewTh,
      );

  Future<void> _push() async {
    await widget.onChanged(_currentSettings());
  }

  @override
  Widget build(BuildContext context) {
    final loc = widget.loc;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(loc.hybridSettingsAutoExec),
              value: _autoExec,
              onChanged: (v) {
                setState(() => _autoExec = v);
                unawaited(_push());
              },
            ),
            const SizedBox(height: 8),
            Text(
              loc.hybridSettingsAutoThreshold,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: Colors.blueGrey.shade900,
              ),
            ),
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
              onChangeEnd: (_) => unawaited(_push()),
            ),
            Text(
              loc.hybridSettingsReviewThreshold,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: Colors.blueGrey.shade900,
              ),
            ),
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
              onChangeEnd: (_) => unawaited(_push()),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: widget.onDisableShield,
              icon: const Icon(Icons.shield_outlined),
              label: Text(loc.adminControlCenterDisableShield),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: widget.onResetLearning,
              icon: Icon(Icons.restart_alt, color: Colors.red.shade800),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade900),
              label: Text(loc.adminControlCenterResetLearning),
            ),
          ],
        ),
      ),
    );
  }
}
