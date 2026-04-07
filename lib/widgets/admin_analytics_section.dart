import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/constants/deal_constants.dart';

/// Business metrics from the `deals` collection (documents supplied by the caller,
/// e.g. the same capped `deals` query as the admin dashboard).
///
/// All metrics use the same base set: deals whose [interestSource] is
/// `property_detail` or `wanted_detail` (within the passed sample).
///
/// - [totalLeads]: count of that set.
/// - [closedDeals]: subset with [dealStatus] `closed`.
/// - [activeDeals]: subset where status is neither `closed` nor `not_interested`.
/// - [conversionPercent]: [closedDeals] ÷ [totalLeads] × 100 (0 if no leads).
///
/// **Today** row:
/// - [todayLeads]: [createdAt] on the device’s local calendar “today”.
/// - [todayClosed]: [dealStatus] `closed` and [closedAt] today; if [closedAt] is
///   missing, falls back to counting closed deals created today (legacy rows).
/// - [todayConversion]: [todayClosed] ÷ [todayLeads] × 100 (0 if no leads).
class AdminAnalyticsSection extends StatelessWidget {
  const AdminAnalyticsSection({
    super.key,
    required this.dealDocs,
    required this.isAr,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;
  final bool isAr;

  static bool _isInterestLead(Map<String, dynamic> m) {
    final src = (m['interestSource'] ?? '').toString();
    return src == 'property_detail' || src == 'wanted_detail';
  }

  static DateTime? _createdAtToDate(Map<String, dynamic> m) {
    final v = m['createdAt'];
    if (v is Timestamp) return v.toDate();
    return null;
  }

  static bool _isSameLocalCalendarDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  static DateTime? _closedAtToDate(Map<String, dynamic> m) {
    final v = m['closedAt'];
    if (v is Timestamp) return v.toDate();
    return null;
  }

  /// True when this closed deal counts as “closed today” for analytics.
  static bool _isClosedToday(
    Map<String, dynamic> m,
    DateTime now,
  ) {
    final st = (m['dealStatus'] ?? '').toString().trim();
    if (st != DealStatus.closed) return false;

    final closedAt = _closedAtToDate(m);
    if (closedAt != null) {
      return _isSameLocalCalendarDay(closedAt, now);
    }

    // Legacy: no closedAt — treat same-day creation + closed as closed “today”
    final created = _createdAtToDate(m);
    if (created != null && _isSameLocalCalendarDay(created, now)) {
      return true;
    }
    return false;
  }

  static _TodayMetrics _computeToday(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    DateTime now,
  ) {
    var todayLeads = 0;
    var todayClosed = 0;

    for (final d in docs) {
      final m = d.data();
      final created = _createdAtToDate(m);
      if (created != null && _isSameLocalCalendarDay(created, now)) {
        todayLeads++;
      }
      if (_isClosedToday(m, now)) {
        todayClosed++;
      }
    }

    final todayConversion =
        todayLeads == 0 ? 0.0 : (todayClosed / todayLeads) * 100.0;

    return _TodayMetrics(
      todayLeads: todayLeads,
      todayClosed: todayClosed,
      todayConversion: todayConversion,
    );
  }

  static _DealAnalyticsMetrics _compute(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final leads = docs.map((d) => d.data()).where(_isInterestLead).toList();
    final totalLeads = leads.length;

    var closedDeals = 0;
    var activeDeals = 0;
    for (final m in leads) {
      final st = (m['dealStatus'] ?? '').toString().trim();
      if (st == DealStatus.closed) closedDeals++;
      if (st != DealStatus.closed && st != DealStatus.notInterested) {
        activeDeals++;
      }
    }

    final conversionPercent =
        totalLeads == 0 ? 0.0 : (closedDeals / totalLeads) * 100.0;
    return _DealAnalyticsMetrics(
      totalLeads: totalLeads,
      closedDeals: closedDeals,
      activeDeals: activeDeals,
      conversionPercent: conversionPercent,
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = _compute(dealDocs);
    final today = _computeToday(dealDocs, DateTime.now());

    Widget metricCard({
      required String label,
      required String value,
      required IconData icon,
      bool compact = false,
    }) {
      final pad = compact ? 10.0 : 14.0;
      final iconSize = compact ? 18.0 : 22.0;
      final labelSize = compact ? 10.5 : 12.0;
      final valueSize = compact ? 14.0 : 17.0;
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(compact ? 12 : 14),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.navy, size: iconSize),
              SizedBox(height: compact ? 6 : 8),
              Text(
                label,
                style: TextStyle(fontSize: labelSize, color: Colors.grey.shade700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: compact ? 2 : 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: valueSize,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final c1 = metricCard(
      label: isAr ? 'إجمالي العملاء المحتملين' : 'Total leads',
      value: '${m.totalLeads}',
      icon: Icons.groups_2_outlined,
    );
    final c2 = metricCard(
      label: isAr ? 'صفقات نشطة' : 'Active deals',
      value: '${m.activeDeals}',
      icon: Icons.pending_actions_outlined,
    );
    final c3 = metricCard(
      label: isAr ? 'صفقات مغلقة' : 'Closed deals',
      value: '${m.closedDeals}',
      icon: Icons.check_circle_outline,
    );
    final c4 = metricCard(
      label: isAr ? 'نسبة الإغلاق' : 'Conversion %',
      value: m.totalLeads == 0
          ? (isAr ? '—' : '—')
          : '${m.conversionPercent.toStringAsFixed(1)}%',
      icon: Icons.percent_outlined,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isAr ? 'لوحة المؤشرات' : 'Analytics',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          isAr
              ? 'من عيّنة deals — مهتمون (تفاصيل عقار / مطلوب) فقط؛ كل المؤشرات من نفس المجموعة.'
              : 'Dashboard deals sample — interest leads only (property / wanted); all metrics use the same set.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 640;
            if (wide) {
              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: c1),
                      const SizedBox(width: 10),
                      Expanded(child: c2),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: c3),
                      const SizedBox(width: 10),
                      Expanded(child: c4),
                    ],
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                c1,
                const SizedBox(height: 10),
                c2,
                const SizedBox(height: 10),
                c3,
                const SizedBox(height: 10),
                c4,
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        Text(
          isAr ? 'مؤشرات اليوم' : 'Today',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          isAr
              ? 'العملاء: تاريخ الإنشاء اليوم. المغلقة: closedAt اليوم (أو نفس يوم الإنشاء إن لم يُحفظ closedAt).'
              : 'Leads: created today. Closed: closedAt today (fallback: created today if closedAt missing).',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 520;
            final t1 = metricCard(
              compact: true,
              label: isAr ? 'عملاء اليوم' : 'Today leads',
              value: '${today.todayLeads}',
              icon: Icons.today_outlined,
            );
            final t2 = metricCard(
              compact: true,
              label: isAr ? 'مغلقة اليوم' : 'Closed today',
              value: '${today.todayClosed}',
              icon: Icons.task_alt_outlined,
            );
            final t3 = metricCard(
              compact: true,
              label: isAr ? 'تحويل اليوم %' : 'Today conversion',
              value: today.todayLeads == 0
                  ? '—'
                  : '${today.todayConversion.toStringAsFixed(1)}%',
              icon: Icons.trending_flat_outlined,
            );
            if (wide) {
              return Row(
                children: [
                  Expanded(child: t1),
                  const SizedBox(width: 8),
                  Expanded(child: t2),
                  const SizedBox(width: 8),
                  Expanded(child: t3),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                t1,
                const SizedBox(height: 8),
                t2,
                const SizedBox(height: 8),
                t3,
              ],
            );
          },
        ),
      ],
    );
  }
}

class _TodayMetrics {
  const _TodayMetrics({
    required this.todayLeads,
    required this.todayClosed,
    required this.todayConversion,
  });

  final int todayLeads;
  final int todayClosed;
  final double todayConversion;
}

class _DealAnalyticsMetrics {
  const _DealAnalyticsMetrics({
    required this.totalLeads,
    required this.closedDeals,
    required this.activeDeals,
    required this.conversionPercent,
  });

  final int totalLeads;
  final int closedDeals;
  final int activeDeals;
  final double conversionPercent;
}
