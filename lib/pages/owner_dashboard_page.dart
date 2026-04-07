import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/chalet_booking_transaction.dart';
import 'package:aqarai_app/services/chalet_booking_transaction_service.dart';

enum _DashboardRange { today, last7, last30, thisMonth }

/// Premium owner overview: chalet ledger metrics, occupancy, chart, recent rows.
/// Uses a single capped Firestore stream (no per-row user fetches).
class OwnerDashboardPage extends StatefulWidget {
  const OwnerDashboardPage({super.key});

  @override
  State<OwnerDashboardPage> createState() => _OwnerDashboardPageState();
}

class _OwnerDashboardPageState extends State<OwnerDashboardPage> {
  static const Color _primary = Color(0xFF101046);
  static const int _queryLimit = 400;
  static const int _listCap = 20;

  _DashboardRange _range = _DashboardRange.last30;

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  (DateTime startInclusive, DateTime endExclusive) _chartWindow() {
    final now = DateTime.now();
    final today = _dateOnly(now);
    switch (_range) {
      case _DashboardRange.today:
        return (today, today.add(const Duration(days: 1)));
      case _DashboardRange.last7:
        return (
          today.subtract(const Duration(days: 6)),
          today.add(const Duration(days: 1)),
        );
      case _DashboardRange.last30:
        return (
          today.subtract(const Duration(days: 29)),
          today.add(const Duration(days: 1)),
        );
      case _DashboardRange.thisMonth:
        final start = DateTime(now.year, now.month, 1);
        return (start, today.add(const Duration(days: 1)));
    }
  }

  List<ChaletBookingTransaction> _parseRows(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final out = <ChaletBookingTransaction>[];
    for (final d in docs) {
      final row = ChaletBookingTransaction.tryParse(d.id, d.data());
      if (row == null || row.isDeleted) continue;
      out.add(row);
    }
    return out;
  }

  DateTime? _referenceDate(ChaletBookingTransaction r) =>
      r.confirmedAt ?? r.createdAt;

  bool _dateInRange(DateTime? dt, DateTime startInclusive, DateTime endExclusive) {
    if (dt == null) return false;
    final d = _dateOnly(dt);
    return !d.isBefore(startInclusive) && d.isBefore(endExclusive);
  }

  bool _payoutReceivedInRange(
    ChaletBookingTransaction r,
    DateTime startInclusive,
    DateTime endExclusive,
  ) {
    if (r.payoutStatus != 'paid') return false;
    final pd = _payoutDay(r);
    return _dateInRange(pd, startInclusive, endExclusive);
  }

  List<ChaletBookingTransaction> _cohortInRange(
    List<ChaletBookingTransaction> all,
    DateTime startInclusive,
    DateTime endExclusive,
  ) {
    return all
        .where((r) => _dateInRange(_referenceDate(r), startInclusive, endExclusive))
        .toList();
  }

  double _occupancyLast30(List<ChaletBookingTransaction> rows) {
    final now = DateTime.now();
    final today = _dateOnly(now);
    final windowStart = today.subtract(const Duration(days: 29));
    final occupied = <DateTime>{};
    for (final r in rows) {
      final s = r.bookingSnapshot?.startDate;
      final e = r.bookingSnapshot?.endDate;
      if (s == null || e == null) continue;
      var d = _dateOnly(s);
      final endDay = _dateOnly(e);
      while (!d.isAfter(endDay)) {
        if (!d.isBefore(windowStart) && !d.isAfter(today)) {
          occupied.add(d);
        }
        d = d.add(const Duration(days: 1));
      }
    }
    return occupied.length / 30.0;
  }

  DateTime? _payoutDay(ChaletBookingTransaction r) {
    if (r.payoutStatus != 'paid') return null;
    return r.paidOutAt ?? r.updatedAt;
  }

  /// Latest paid activity timestamp for “live” feedback (same fields as payout day).
  DateTime? _latestPaidPayoutTimestamp(List<ChaletBookingTransaction> rows) {
    DateTime? latest;
    for (final r in rows) {
      if (r.payoutStatus != 'paid') continue;
      final t = r.paidOutAt ?? r.updatedAt;
      if (t == null) continue;
      if (latest == null || t.isAfter(latest)) latest = t;
    }
    return latest;
  }

  String _relativePastPhrase(DateTime past, AppLocalizations loc) {
    final now = DateTime.now();
    var d = now.difference(past);
    if (d.isNegative) d = Duration.zero;
    if (d.inSeconds < 45) return loc.ownerDashboardRelativeJustNow;
    if (d.inMinutes < 60) {
      final m = d.inMinutes < 1 ? 1 : d.inMinutes;
      return loc.ownerDashboardRelativeMinutesAgo(m);
    }
    if (d.inHours < 48) {
      final h = d.inHours < 1 ? 1 : d.inHours;
      return loc.ownerDashboardRelativeHoursAgo(h);
    }
    final days = d.inDays < 1 ? 1 : d.inDays;
    return loc.ownerDashboardRelativeDaysAgo(days);
  }

  List<FlSpot> _chartSpots(List<ChaletBookingTransaction> rows) {
    final (start, endEx) = _chartWindow();
    final days = <DateTime>[];
    for (var d = start; d.isBefore(endEx); d = d.add(const Duration(days: 1))) {
      days.add(d);
    }
    if (days.isEmpty) return [];

    final byDay = <DateTime, double>{};
    for (final r in rows) {
      final pd = _payoutDay(r);
      if (pd == null) continue;
      final key = _dateOnly(pd);
      if (key.isBefore(start) || !key.isBefore(endEx)) continue;
      byDay[key] = (byDay[key] ?? 0) + r.ownerPayoutAmount;
    }

    final spots = <FlSpot>[];
    for (var i = 0; i < days.length; i++) {
      final v = byDay[days[i]] ?? 0;
      spots.add(FlSpot(i.toDouble(), v));
    }
    return spots;
  }

  String _ledgerStatusLabel(ChaletBookingTransaction r, AppLocalizations loc) {
    if (r.refundStatus != 'none' || r.status == 'refunded') {
      return loc.ownerDashboardStatusRefunded;
    }
    if (r.payoutStatus == 'paid') return loc.ownerDashboardStatusPaid;
    return loc.ownerDashboardStatusPending;
  }

  Color _statusColor(ChaletBookingTransaction r) {
    if (r.refundStatus != 'none' || r.status == 'refunded') return Colors.purple.shade700;
    if (r.payoutStatus == 'paid') return Colors.green.shade700;
    return Colors.orange.shade800;
  }

  /// Paid totals in [cohort] by property; empty if fewer than two properties.
  List<({int rank, String label, double total})> _rankedChaletsByPaid(
    List<ChaletBookingTransaction> cohort,
  ) {
    final totals = <String, double>{};
    final titles = <String, String>{};
    for (final r in cohort) {
      if (r.payoutStatus != 'paid') continue;
      final pid = r.propertyId.trim();
      if (pid.isEmpty) continue;
      totals[pid] = (totals[pid] ?? 0) + r.ownerPayoutAmount;
      final t = r.bookingSnapshot?.propertyTitle?.trim();
      if (t != null && t.isNotEmpty) titles[pid] = t;
    }
    if (totals.length < 2) return [];
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return List.generate(sorted.length, (i) {
      final e = sorted[i];
      final label = titles[e.key]?.isNotEmpty == true ? titles[e.key]! : e.key;
      return (rank: i + 1, label: label, total: e.value);
    });
  }

  double _sumPaidInRange(
    List<ChaletBookingTransaction> all,
    DateTime startInclusive,
    DateTime endExclusive,
  ) {
    var t = 0.0;
    for (final r in all) {
      if (_payoutReceivedInRange(r, startInclusive, endExclusive)) {
        t += r.ownerPayoutAmount;
      }
    }
    return t;
  }

  List<String> _insights(List<ChaletBookingTransaction> all, AppLocalizations loc) {
    final out = <String>[];
    final now = DateTime.now();
    final today = _dateOnly(now);
    final curStart = today.subtract(const Duration(days: 6));
    final curEnd = today.add(const Duration(days: 1));
    final prevStart = today.subtract(const Duration(days: 13));
    final prevEnd = today.subtract(const Duration(days: 6));

    final curW = _sumPaidInRange(all, curStart, curEnd);
    final prevW = _sumPaidInRange(all, prevStart, prevEnd);
    if (prevW > 0 && curW > prevW * 1.02) {
      out.add(loc.ownerDashboardInsightEarningsUp);
    }

    final refStart = today.subtract(const Duration(days: 13));
    final hasRecentBooking = all.any(
      (r) => _dateInRange(_referenceDate(r), refStart, curEnd),
    );
    if (all.isNotEmpty && !hasRecentBooking) {
      out.add(loc.ownerDashboardInsightNoRecentBookings);
    }

    final occ = _occupancyLast30(all);
    if (occ >= 0.5) {
      out.add(loc.ownerDashboardInsightHighOccupancy);
    }
    return out;
  }

  Widget _animatedMetricValue(
    String text, {
    required ValueKey<String> valueKey,
    required TextStyle style,
  }) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.05),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: Text(
        text,
        key: valueKey,
        style: style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _heroPaidMetric({
    required String emoji,
    required String title,
    required String valueText,
    required String subtitle,
  }) {
    return Card(
      elevation: 4,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _primary.withValues(alpha: 0.35), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(emoji, style: const TextStyle(fontSize: 26)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.grey.shade900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _animatedMetricValue(
              valueText,
              valueKey: ValueKey(valueText),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: _primary,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricCard({
    required String emoji,
    required String title,
    required String value,
    required String subtitle,
    required Color accent,
  }) {
    return Card(
      elevation: 3,
      shadowColor: Colors.black26,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(emoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _animatedMetricValue(
              value,
              valueKey: ValueKey(value),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final fmt = NumberFormat.decimalPattern();
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: Text(loc.ownerDashboardTitle)),
        body: const Center(child: Text('—')),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        title: Text(loc.ownerDashboardTitle),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: ChaletBookingTransactionService.ownerDashboardTransactionsQuery(
          uid,
          limit: _queryLimit,
        ).snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final rows = _parseRows(snap.data?.docs ?? const []);

          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  loc.ownerDashboardEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 16),
                ),
              ),
            );
          }

          final (wStart, wEndEx) = _chartWindow();
          final cohort = _cohortInRange(rows, wStart, wEndEx);

          var paidTotal = 0.0;
          for (final r in rows) {
            if (_payoutReceivedInRange(r, wStart, wEndEx)) {
              paidTotal += r.ownerPayoutAmount;
            }
          }

          var pendingTotal = 0.0;
          var commissionTotal = 0.0;
          for (final r in cohort) {
            if (r.payoutStatus == 'pending') {
              pendingTotal += r.ownerPayoutAmount;
            }
            commissionTotal += r.platformRevenue;
          }

          final bookingsCount = cohort.length;
          final occ = _occupancyLast30(rows);
          final spots = _chartSpots(rows);
          final maxY = spots.isEmpty
              ? 1.0
              : spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
          final chartMaxY = maxY <= 0 ? 1.0 : maxY * 1.15;
          final ranked = _rankedChaletsByPaid(cohort);
          final insightLines = _insights(rows, loc);
          final currency = rows.first.currency;
          final dateFmt = DateFormat.yMMMd(Localizations.localeOf(context).toString());

          final listRows = [...cohort]..sort((a, b) {
              final da = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
              final db = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
              return db.compareTo(da);
            });
          final listTrimmed = listRows.take(_listCap).toList();

          final lastPaidAt = _latestPaidPayoutTimestamp(rows);
          final lastPayoutCaption = lastPaidAt != null
              ? loc.ownerDashboardLastPayoutLine(_relativePastPhrase(lastPaidAt, loc))
              : loc.ownerDashboardLastPayoutNone;

          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.ownerDashboardSubtitle,
                        style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
                      ),
                      const SizedBox(height: 10),
                      Material(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                loc.ownerDashboardDataLimitLabel(_queryLimit),
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.blue.shade900,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                loc.ownerDashboardDataLimitHint,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.blue.shade800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<_DashboardRange>(
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: WidgetStateProperty.resolveWith((s) {
                            if (s.contains(WidgetState.selected)) return Colors.white;
                            return _primary;
                          }),
                          backgroundColor: WidgetStateProperty.resolveWith((s) {
                            if (s.contains(WidgetState.selected)) return _primary;
                            return Colors.white;
                          }),
                        ),
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(
                            value: _DashboardRange.today,
                            label: Text(loc.ownerDashboardRangeToday),
                          ),
                          ButtonSegment(
                            value: _DashboardRange.last7,
                            label: Text(loc.ownerDashboardRange7),
                          ),
                          ButtonSegment(
                            value: _DashboardRange.last30,
                            label: Text(loc.ownerDashboardRange30),
                          ),
                          ButtonSegment(
                            value: _DashboardRange.thisMonth,
                            label: Text(loc.ownerDashboardRangeMonth),
                          ),
                        ],
                        selected: {_range},
                        onSelectionChanged: (s) {
                          if (s.isEmpty) return;
                          setState(() => _range = s.first);
                        },
                      ),
                    ),
                  ),
                ),
              ),
              if (cohort.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Material(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.orange.shade900),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                loc.ownerDashboardEmptyFiltered,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.orange.shade900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (insightLines.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              loc.ownerDashboardInsightsTitle,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 10),
                            ...insightLines.map(
                              (line) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  line,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade800,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _heroPaidMetric(
                        emoji: '💰',
                        title: loc.ownerDashboardMetricPaid,
                        valueText: '${fmt.format(paidTotal)} $currency',
                        subtitle:
                            '${loc.ownerDashboardMetricPeriodSubtitle} · ${loc.ownerDashboardStatusPaid}',
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.bolt_outlined, size: 18, color: Colors.teal.shade700),
                          const SizedBox(width: 6),
                          Expanded(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 260),
                              switchInCurve: Curves.easeOut,
                              child: Text(
                                lastPayoutCaption,
                                key: ValueKey(lastPayoutCaption),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade800,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, c) {
                          final narrow = c.maxWidth < 520;
                          final pendingCard = _metricCard(
                            emoji: '⏳',
                            title: loc.ownerDashboardMetricPending,
                            value: '${fmt.format(pendingTotal)} $currency',
                            subtitle:
                                '${loc.ownerDashboardMetricPeriodSubtitle} · ${loc.ownerDashboardStatusPending}',
                            accent: Colors.orange.shade800,
                          );
                          final bookingsCard = _metricCard(
                            emoji: '🏠',
                            title: loc.ownerDashboardMetricBookings,
                            value: '$bookingsCount',
                            subtitle: loc.ownerDashboardMetricPeriodSubtitle,
                            accent: _primary,
                          );
                          final commissionCard = _metricCard(
                            emoji: '📊',
                            title: loc.ownerDashboardMetricCommission,
                            value: '${fmt.format(commissionTotal)} $currency',
                            subtitle: loc.ownerDashboardMetricPeriodSubtitle,
                            accent: Colors.blueGrey.shade700,
                          );
                          if (narrow) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                pendingCard,
                                const SizedBox(height: 12),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: bookingsCard),
                                    const SizedBox(width: 12),
                                    Expanded(child: commissionCard),
                                  ],
                                ),
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: pendingCard),
                              const SizedBox(width: 12),
                              Expanded(child: bookingsCard),
                              const SizedBox(width: 12),
                              Expanded(child: commissionCard),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Card(
                    elevation: 3,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('📊', style: TextStyle(fontSize: 20)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  loc.ownerDashboardOccupancyTitle,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            loc.ownerDashboardOccupancyHint,
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                          const SizedBox(height: 16),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LinearProgressIndicator(
                              value: occ.clamp(0.0, 1.0),
                              minHeight: 10,
                              backgroundColor: Colors.grey.shade200,
                              color: _primary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${(occ * 100).toStringAsFixed(1)}%',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: _primary,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Card(
                    elevation: 3,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('💰', style: TextStyle(fontSize: 20)),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  loc.ownerDashboardChartTitle,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            loc.ownerDashboardChartSubtitle,
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            loc.ownerDashboardChartPaidOnly,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _primary,
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 200,
                            child: spots.every((s) => s.y == 0)
                                ? Center(
                                    child: Text(
                                      loc.ownerDashboardChartNoActivity,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: Colors.grey.shade600),
                                    ),
                                  )
                                : LineChart(
                                    LineChartData(
                                      gridData: FlGridData(
                                        show: true,
                                        drawVerticalLine: false,
                                        horizontalInterval: chartMaxY > 5 ? chartMaxY / 4 : 1,
                                        getDrawingHorizontalLine: (_) => FlLine(
                                          color: Colors.grey.shade200,
                                          strokeWidth: 1,
                                        ),
                                      ),
                                      titlesData: FlTitlesData(
                                        leftTitles: AxisTitles(
                                          sideTitles: SideTitles(
                                            showTitles: true,
                                            reservedSize: 40,
                                            getTitlesWidget: (v, _) => Text(
                                              fmt.format(v),
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
                                            interval: spots.length <= 7
                                                ? 1
                                                : (spots.length / 4).ceilToDouble(),
                                            getTitlesWidget: (v, _) {
                                              final i = v.round();
                                              if (i < 0 || i >= spots.length) {
                                                return const SizedBox.shrink();
                                              }
                                              final (start, _) = _chartWindow();
                                              final d = start.add(Duration(days: i));
                                              return Padding(
                                                padding: const EdgeInsets.only(top: 8),
                                                child: Text(
                                                  DateFormat.Md(
                                                    Localizations.localeOf(context).toString(),
                                                  ).format(d),
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: Colors.grey.shade700,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                        rightTitles: const AxisTitles(
                                          sideTitles: SideTitles(showTitles: false),
                                        ),
                                        topTitles: const AxisTitles(
                                          sideTitles: SideTitles(showTitles: false),
                                        ),
                                      ),
                                      borderData: FlBorderData(show: false),
                                      minX: 0,
                                      maxX: (spots.length - 1).toDouble(),
                                      minY: 0,
                                      maxY: chartMaxY,
                                      lineBarsData: [
                                        LineChartBarData(
                                          spots: spots,
                                          isCurved: true,
                                          curveSmoothness: 0.25,
                                          color: _primary,
                                          barWidth: 3,
                                          dotData: FlDotData(
                                            show: true,
                                            getDotPainter: (s, p, b, i) =>
                                                FlDotCirclePainter(
                                              radius: 3,
                                              color: _primary,
                                              strokeWidth: 0,
                                            ),
                                          ),
                                          belowBarData: BarAreaData(
                                            show: true,
                                            color: _primary.withValues(alpha: 0.12),
                                          ),
                                        ),
                                      ],
                                    ),
                                    duration: const Duration(milliseconds: 380),
                                    curve: Curves.easeOutCubic,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (ranked.length >= 2)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Card(
                      elevation: 3,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                              child: Text(
                                loc.ownerDashboardRankingTitle,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            for (final e in ranked.take(5))
                              ListTile(
                                dense: true,
                                leading: CircleAvatar(
                                  radius: 16,
                                  backgroundColor: e.rank == 1
                                      ? Colors.amber.shade100
                                      : _primary.withValues(alpha: 0.1),
                                  child: Text(
                                    '${e.rank}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: e.rank == 1
                                          ? Colors.amber.shade900
                                          : _primary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  e.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Text(
                                  '${fmt.format(e.total)} $currency',
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      const Text('🏠', style: TextStyle(fontSize: 18)),
                      const SizedBox(width: 8),
                      Text(
                        loc.ownerDashboardRecentBookings,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    loc.ownerDashboardListLimitNote(_listCap),
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final r = listTrimmed[i];
                    final start = r.bookingSnapshot?.startDate;
                    final end = r.bookingSnapshot?.endDate;
                    final rangeStr = start != null && end != null
                        ? '${dateFmt.format(start)} — ${dateFmt.format(end)}'
                        : '—';
                    final title = (r.bookingSnapshot?.propertyTitle?.trim().isNotEmpty == true)
                        ? r.bookingSnapshot!.propertyTitle!.trim()
                        : r.propertyId;
                    final stLabel = _ledgerStatusLabel(r, loc);
                    return Card(
                      margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                      elevation: 2,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        title: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(rangeStr),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${fmt.format(r.amount)} ${r.currency}',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: _statusColor(r).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                stLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _statusColor(r),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  childCount: listTrimmed.length,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    );
  }
}
