import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/utils/kuwait_calendar.dart';

enum _MetricsRange { today, thisMonth, allTime }

class AdminBookingAnalyticsSection extends StatefulWidget {
  const AdminBookingAnalyticsSection({
    super.key,
    required this.isAr,
    required this.fmtKwd,
  });

  final bool isAr;
  final String Function(num n) fmtKwd;

  @override
  State<AdminBookingAnalyticsSection> createState() =>
      _AdminBookingAnalyticsSectionState();
}

class _AdminBookingAnalyticsSectionState extends State<AdminBookingAnalyticsSection>
    with WidgetsBindingObserver {
  static const String _na = '—';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  _MetricsRange _range = _MetricsRange.today;

  late String _kuwaitDayKey;
  late String _kuwaitMonthKey;

  late Stream<DocumentSnapshot<Map<String, dynamic>>> _financeStream;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _dailyStream;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _monthlyStream;

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse((v ?? '0').toString().trim()) ?? 0;
  }

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse((v ?? '0').toString().trim()) ?? 0;
  }

  static DateTime? _ts(dynamic v) => v is Timestamp ? v.toDate() : null;

  static String _dayKeyFromKuwaitDate(DateTime kuwaitDateOnly) {
    final y = kuwaitDateOnly.year;
    final m = kuwaitDateOnly.month.toString().padLeft(2, '0');
    final d = kuwaitDateOnly.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _monthKeyFromKuwaitDate(DateTime kuwaitDateOnly) {
    final y = kuwaitDateOnly.year;
    final m = kuwaitDateOnly.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  void _bindStreamsForKuwaitNow() {
    final kuwaitDay = KuwaitCalendar.kuwaitTodayDateOnly();
    _kuwaitDayKey = _dayKeyFromKuwaitDate(kuwaitDay);
    _kuwaitMonthKey = _monthKeyFromKuwaitDate(kuwaitDay);

    _financeStream =
        _db.collection('admin_metrics').doc('finance').snapshots();
    _dailyStream = _db
        .collection('admin_metrics_daily')
        .doc(_kuwaitDayKey)
        .snapshots();
    _monthlyStream = _db
        .collection('admin_metrics_monthly')
        .doc(_kuwaitMonthKey)
        .snapshots();
  }

  void _maybeRotateKuwaitStreams() {
    final kuwaitDay = KuwaitCalendar.kuwaitTodayDateOnly();
    final nextDay = _dayKeyFromKuwaitDate(kuwaitDay);
    final nextMonth = _monthKeyFromKuwaitDate(kuwaitDay);
    if (nextDay != _kuwaitDayKey || nextMonth != _kuwaitMonthKey) {
      setState(_bindStreamsForKuwaitNow);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindStreamsForKuwaitNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeRotateKuwaitStreams();
    }
  }

  Map<String, dynamic>? _periodMap({
    required _MetricsRange range,
    required DocumentSnapshot<Map<String, dynamic>>? daily,
    required DocumentSnapshot<Map<String, dynamic>>? monthly,
    required DocumentSnapshot<Map<String, dynamic>>? finance,
  }) {
    switch (range) {
      case _MetricsRange.today:
        if (daily == null || !daily.exists) return null;
        return daily.data();
      case _MetricsRange.thisMonth:
        if (monthly == null || !monthly.exists) return null;
        return monthly.data();
      case _MetricsRange.allTime:
        if (finance == null || !finance.exists) return null;
        return finance.data();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _financeStream,
      builder: (context, financeSnap) {
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _dailyStream,
          builder: (context, dailySnap) {
            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _monthlyStream,
              builder: (context, monthlySnap) {
                final loading = (financeSnap.connectionState ==
                        ConnectionState.waiting &&
                    !financeSnap.hasData) ||
                    (dailySnap.connectionState == ConnectionState.waiting &&
                        !dailySnap.hasData) ||
                    (monthlySnap.connectionState == ConnectionState.waiting &&
                        !monthlySnap.hasData);

                if (loading) {
                  return _SectionShell(
                    title: isAr ? 'تحليلات الحجوزات' : 'Booking Analytics',
                    subtitle: isAr ? 'مباشر من الخادم' : 'Live (server)',
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(20),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 14),
                            Expanded(child: Text('…')),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                if (financeSnap.hasError ||
                    dailySnap.hasError ||
                    monthlySnap.hasError) {
                  return _SectionShell(
                    title: isAr ? 'تحليلات الحجوزات' : 'Booking Analytics',
                    subtitle: isAr ? 'مباشر من الخادم' : 'Live (server)',
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Text(
                          isAr
                              ? 'تعذر تحميل المؤشرات'
                              : 'Could not load metrics',
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                      ),
                    ),
                  );
                }

                final periodM = _periodMap(
                  range: _range,
                  daily: dailySnap.data,
                  monthly: monthlySnap.data,
                  finance: financeSnap.data,
                );

                final totalBookings =
                    periodM != null ? _int(periodM['totalBookings']) : 0;
                final totalRevenue =
                    periodM != null ? _num(periodM['totalRevenue']) : 0.0;
                final totalCommission =
                    periodM != null ? _num(periodM['totalCommission']) : 0.0;

                final todayDoc = dailySnap.data;
                final todayBookings = (todayDoc != null && todayDoc.exists)
                    ? _int(todayDoc.data()!['totalBookings'])
                    : 0;

                final updatedAt = periodM != null ? _ts(periodM['updatedAt']) : null;
                final updatedLabel = updatedAt == null
                    ? _na
                    : DateFormat.yMMMd(isAr ? 'ar' : 'en_US')
                        .add_jm()
                        .format(updatedAt);

                Widget metricRowOrCol(List<Widget> children) {
                  return LayoutBuilder(
                    builder: (context, c) {
                      final wide = c.maxWidth > 560;
                      const spacing = 10.0;
                      if (wide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < children.length; i++) ...[
                              if (i > 0) const SizedBox(width: spacing),
                              Expanded(child: children[i]),
                            ],
                          ],
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < children.length; i++) ...[
                            if (i > 0) const SizedBox(height: spacing),
                            children[i],
                          ],
                        ],
                      );
                    },
                  );
                }

                final rangeLabel = switch (_range) {
                  _MetricsRange.today =>
                    isAr ? 'اليوم (الكويت)' : 'Today (Kuwait)',
                  _MetricsRange.thisMonth =>
                    isAr ? 'هذا الشهر (الكويت)' : 'This month (Kuwait)',
                  _MetricsRange.allTime => isAr ? 'كل الأوقات' : 'All time',
                };

                return _SectionShell(
                  title: isAr ? 'تحليلات الحجوزات' : 'Booking Analytics',
                  subtitle: isAr
                      ? 'مباشر من الخادم · $rangeLabel'
                      : 'Live (server) · $rangeLabel',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<_MetricsRange>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment<_MetricsRange>(
                            value: _MetricsRange.today,
                            label: Text(isAr ? 'اليوم' : 'Today'),
                          ),
                          ButtonSegment<_MetricsRange>(
                            value: _MetricsRange.thisMonth,
                            label: Text(isAr ? 'الشهر' : 'Month'),
                          ),
                          ButtonSegment<_MetricsRange>(
                            value: _MetricsRange.allTime,
                            label: Text(isAr ? 'الكل' : 'All time'),
                          ),
                        ],
                        selected: {_range},
                        onSelectionChanged: (next) {
                          if (next.isEmpty) return;
                          setState(() => _range = next.first);
                        },
                      ),
                      const SizedBox(height: 12),
                      metricRowOrCol([
                        _MetricCard(
                          label: isAr ? 'إجمالي الحجوزات' : 'Total bookings',
                          value: fmt.format(totalBookings),
                          icon: Icons.event_available_outlined,
                          accent: AppColors.navy,
                        ),
                        _MetricCard(
                          label: isAr ? 'إجمالي الليالي' : 'Total nights',
                          value: _na,
                          icon: Icons.nights_stay_outlined,
                          accent: Colors.indigo.shade700,
                        ),
                        _MetricCard(
                          label: isAr ? 'اليوم' : 'Today',
                          value: fmt.format(todayBookings),
                          icon: Icons.today_outlined,
                          accent: Colors.teal.shade700,
                          foot: isAr ? 'عدد الحجوزات' : 'Bookings',
                        ),
                      ]),
                      const SizedBox(height: 10),
                      metricRowOrCol([
                        _MetricCard(
                          label: isAr ? 'إجمالي الإيراد' : 'Total revenue',
                          value: widget.fmtKwd(totalRevenue),
                          icon: Icons.account_balance_wallet_outlined,
                          accent: Colors.green.shade800,
                          strong: true,
                        ),
                        _MetricCard(
                          label: isAr ? 'إجمالي العمولة' : 'Total commission',
                          value: widget.fmtKwd(totalCommission),
                          icon: Icons.payments_outlined,
                          accent: Colors.orange.shade800,
                          strong: true,
                        ),
                        _MetricCard(
                          label: isAr ? 'صافي المالك' : 'Owner net',
                          value: _na,
                          icon: Icons.person_outline,
                          accent: Colors.grey.shade800,
                          foot: isAr ? 'قبل الصرف' : 'Before payout',
                        ),
                      ]),
                      const SizedBox(height: 10),
                      Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: Colors.grey.shade200),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.sync_outlined,
                                color: Colors.blueGrey.shade700,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  isAr
                                      ? 'آخر تحديث: $updatedLabel'
                                      : 'Last updated: $updatedLabel',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.grey.shade800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _SectionShell extends StatelessWidget {
  const _SectionShell({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.navy,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
    this.strong = false,
    this.foot,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color accent;
  final bool strong;
  final String? foot;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: accent, size: 22),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: strong ? 18 : 16,
                fontWeight: FontWeight.w900,
                color: strong ? accent : AppColors.navy,
                letterSpacing: -0.2,
              ),
            ),
            if (foot != null && foot!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                foot!,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
