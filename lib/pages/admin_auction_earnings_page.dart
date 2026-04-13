import 'dart:math' as math;

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/services/admin_real_earnings_service.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/utils/kuwait_calendar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Admin-only: **real** revenue from Firestore (`auction_requests` paid fees +
/// `deals` with finalized `dealStatus` signed/closed). Full query snapshots.
class AdminAuctionEarningsPage extends StatefulWidget {
  const AdminAuctionEarningsPage({super.key});

  @override
  State<AdminAuctionEarningsPage> createState() =>
      _AdminAuctionEarningsPageState();
}

class _AdminAuctionEarningsPageState extends State<AdminAuctionEarningsPage> {
  Future<bool> _adminGate = AuthService.isAdmin();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  EarningsDateRangePreset _datePreset = EarningsDateRangePreset.allTime;

  void _retryGate() => setState(() => _adminGate = AuthService.isAdmin());

  String _fmtKwd(num n, bool isAr) {
    final s = n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
    return isAr ? '$s د.ك' : '$s KWD';
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return FutureBuilder<bool>(
      future: _adminGate,
      builder: (context, gate) {
        if (gate.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.adminAuctionEarningsTitle)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (gate.data != true) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.adminAuctionEarningsTitle)),
            body: _AccessDenied(isAr: isAr, onRetry: _retryGate),
          );
        }

        final range = EarningsDateRange.fromPreset(_datePreset);
        final paidQ = AdminRealEarningsService.paidAuctionRequestsQuery(
          _db,
          preset: _datePreset,
        );
        final soldQ = AdminRealEarningsService.soldDealsQuery(
          _db,
          preset: _datePreset,
        );

        return Scaffold(
          backgroundColor: const Color(0xFFF7F7F7),
          appBar: AppBar(
            title: Text(loc.adminAuctionEarningsTitle),
            backgroundColor: AppColors.navy,
            foregroundColor: Colors.white,
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: SegmentedButton<EarningsDateRangePreset>(
                  segments: [
                    ButtonSegment<EarningsDateRangePreset>(
                      value: EarningsDateRangePreset.allTime,
                      label: Text(loc.adminEarningsFilterAllTime),
                    ),
                    ButtonSegment<EarningsDateRangePreset>(
                      value: EarningsDateRangePreset.today,
                      label: Text(loc.adminEarningsFilterToday),
                    ),
                    ButtonSegment<EarningsDateRangePreset>(
                      value: EarningsDateRangePreset.last7Days,
                      label: Text(loc.adminEarningsFilterLast7Days),
                    ),
                    ButtonSegment<EarningsDateRangePreset>(
                      value: EarningsDateRangePreset.last30Days,
                      label: Text(loc.adminEarningsFilterLast30Days),
                    ),
                  ],
                  selected: {_datePreset},
                  onSelectionChanged: (Set<EarningsDateRangePreset> s) {
                    setState(() => _datePreset = s.first);
                  },
                ),
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: paidQ.snapshots(),
                  builder: (context, paidSnap) {
                    if (paidSnap.hasError) {
                      return _ErrorBody(message: '${paidSnap.error}');
                    }
                    final paidWaiting =
                        paidSnap.connectionState == ConnectionState.waiting &&
                        !paidSnap.hasData;

                    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: soldQ.snapshots(),
                      builder: (context, soldSnap) {
                        if (soldSnap.hasError) {
                          return _ErrorBody(message: '${soldSnap.error}');
                        }
                        final soldWaiting =
                            soldSnap.connectionState ==
                                    ConnectionState.waiting &&
                                !soldSnap.hasData;

                        if (paidWaiting || soldWaiting) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }

                        final paid = paidSnap.data!;
                        final sold = soldSnap.data!;
                        final agg = AdminRealEarningsService.aggregate(
                          paid,
                          sold,
                          filterRange: range,
                        );

                        return ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                          children: [
                            Text(
                              loc.adminRealEarningsHint,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade800,
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 14),
                            _MetricCardGrid(
                              agg: agg,
                              loc: loc,
                              fmt: (n) => _fmtKwd(n, isAr),
                            ),
                            const SizedBox(height: 20),
                            _RevenueBreakdownSection(
                              agg: agg,
                              loc: loc,
                              fmt: (n) => _fmtKwd(n, isAr),
                            ),
                            const SizedBox(height: 14),
                            Material(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(Icons.info_outline,
                                        color: Colors.blue.shade900),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        loc.adminRealEarningsLegacyNote,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.blue.shade900,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 22),
                            Text(
                              loc.adminAuctionEarningsChartTitle,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: AppColors.navy,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              loc.adminAuctionEarningsChartSubtitle,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                              ),
                            ),
                            const SizedBox(height: 14),
                            _RevenueLineChart(
                              series: agg.dailyRevenue,
                              emptyLabel: loc.adminRealEarningsChartEmpty,
                              isAr: isAr,
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
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
            Text(isAr ? 'غير مصرّح' : 'Not authorized'),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(isAr ? 'إعادة' : 'Retry')),
          ],
        ),
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}

class _MetricCardGrid extends StatelessWidget {
  const _MetricCardGrid({
    required this.agg,
    required this.loc,
    required this.fmt,
  });

  final RealEarningsSnapshot agg;
  final AppLocalizations loc;
  final String Function(num) fmt;

  @override
  Widget build(BuildContext context) {
    Widget metricCard({
      required IconData icon,
      required String title,
      required String value,
      EdgeInsetsGeometry padding = const EdgeInsets.all(14),
    }) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: AppColors.navy, size: 24),
              const SizedBox(height: 10),
              Text(
                title,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        metricCard(
          icon: Icons.trending_up,
          title: loc.adminRealEarningsTotalRevenue,
          value: fmt(agg.totalRevenueKwd),
          padding: const EdgeInsets.fromLTRB(14, 22, 14, 22),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: metricCard(
                icon: Icons.gavel,
                title: loc.adminAuctionEarningsPaidListings,
                value: '${agg.paidAuctionCount}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: metricCard(
                icon: Icons.handshake_outlined,
                title: loc.adminAuctionEarningsDealsCompleted,
                value: '${agg.soldDealCount}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RevenueBreakdownSection extends StatelessWidget {
  const _RevenueBreakdownSection({
    required this.agg,
    required this.loc,
    required this.fmt,
  });

  final RealEarningsSnapshot agg;
  final AppLocalizations loc;
  final String Function(num) fmt;

  String _shareLabel(double part) {
    final total = agg.totalRevenueKwd;
    if (total <= 0) return '—';
    final pct = (100.0 * part / total).clamp(0.0, 100.0);
    final s = pct == pct.roundToDouble()
        ? pct.round().toString()
        : pct.toStringAsFixed(1);
    return loc.adminEarningsShareOfTotal(s);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          loc.adminEarningsRevenueBreakdownTitle,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 520;
            final feesCard = _BreakdownMoneyCard(
              accent: const Color(0xFF1565C0),
              icon: Icons.payments_outlined,
              title: loc.adminAuctionEarningsTotalFees,
              amountLabel: fmt(agg.totalAuctionFeesKwd),
              shareLabel: _shareLabel(agg.totalAuctionFeesKwd),
            );
            final commCard = _BreakdownMoneyCard(
              accent: const Color(0xFF00897B),
              icon: Icons.account_balance_wallet_outlined,
              title: loc.adminAuctionEarningsEstCommission,
              amountLabel: fmt(agg.totalCommissionKwd),
              shareLabel: _shareLabel(agg.totalCommissionKwd),
            );
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: feesCard),
                  const SizedBox(width: 12),
                  Expanded(child: commCard),
                ],
              );
            }
            return Column(
              children: [
                feesCard,
                const SizedBox(height: 10),
                commCard,
              ],
            );
          },
        ),
      ],
    );
  }
}

class _BreakdownMoneyCard extends StatelessWidget {
  const _BreakdownMoneyCard({
    required this.accent,
    required this.icon,
    required this.title,
    required this.amountLabel,
    required this.shareLabel,
  });

  final Color accent;
  final IconData icon;
  final String title;
  final String amountLabel;
  final String shareLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(color: accent, width: 4),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: accent, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              amountLabel,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.grey.shade900,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              shareLabel,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RevenueLineChart extends StatelessWidget {
  const _RevenueLineChart({
    required this.series,
    required this.emptyLabel,
    required this.isAr,
  });

  final List<DailyRevenuePoint> series;
  final String emptyLabel;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    if (series.isEmpty) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              emptyLabel,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700),
            ),
          ),
        ),
      );
    }

    final spots = <FlSpot>[];
    for (var i = 0; i < series.length; i++) {
      spots.add(FlSpot(i.toDouble(), series[i].revenueKwd));
    }

    final maxY = series.map((e) => e.revenueKwd).reduce(math.max);
    final chartMaxY = math.max(maxY * 1.12, 1.0);

    final locale = isAr ? 'ar' : 'en';

    String labelForIndex(int i) {
      if (i < 0 || i >= series.length) return '';
      return KuwaitCalendar.formatDayKeyMedium(series[i].dayKey, locale);
    }

    final labelEvery = series.length > 14 ? (series.length / 7).ceil() : 1;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 18, 16, 12),
        child: SizedBox(
          height: 260,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: series.length <= 1 ? 1 : (series.length - 1).toDouble(),
              minY: 0,
              maxY: chartMaxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: chartMaxY > 5 ? chartMaxY / 4 : null,
                getDrawingHorizontalLine: (v) =>
                    FlLine(color: Colors.grey.shade200, strokeWidth: 1),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    getTitlesWidget: (v, m) => Text(
                      v >= 1000
                          ? '${(v / 1000).toStringAsFixed(1)}k'
                          : v.toStringAsFixed(0),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: 1,
                    getTitlesWidget: (v, m) {
                      final i = v.round();
                      if (i < 0 || i >= series.length) {
                        return const SizedBox.shrink();
                      }
                      if (i % labelEvery != 0 && i != series.length - 1) {
                        return const SizedBox.shrink();
                      }
                      final short = labelForIndex(i);
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          short.length > 10
                              ? '${short.substring(0, 9)}…'
                              : short,
                          style: TextStyle(
                            fontSize: 9,
                            color: Colors.grey.shade700,
                          ),
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
                  color: const Color(0xFF1565C0),
                  barWidth: 3,
                  dotData: const FlDotData(show: true),
                  belowBarData: BarAreaData(
                    show: true,
                    color: const Color(0xFF1565C0).withValues(alpha: 0.12),
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
                      if (i < 0 || i >= series.length) continue;
                      final p = series[i];
                      out.add(
                        LineTooltipItem(
                          '${p.dayKey}\n${p.revenueKwd.toStringAsFixed(2)}',
                          const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      );
                    }
                    return out;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
