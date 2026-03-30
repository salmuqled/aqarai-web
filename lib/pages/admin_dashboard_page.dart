import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/admin_analytics_models.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/admin_analytics_service.dart';
import 'package:aqarai_app/services/admin_intelligence_service.dart';
import 'package:aqarai_app/services/admin_recommendations_service.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/widgets/admin_notification_performance_section.dart';
import 'package:aqarai_app/widgets/admin_recommendation_widgets.dart';
import 'package:aqarai_app/widgets/admin_caption_learning_section.dart';
import 'package:aqarai_app/widgets/admin_decision_accuracy_section.dart';
import 'package:aqarai_app/widgets/admin_caption_performance_section.dart';
import 'package:aqarai_app/widgets/admin_instagram_post_dialog.dart';
import 'package:aqarai_app/pages/admin_control_center_page.dart';
import 'package:aqarai_app/widgets/hybrid_marketing_settings_dialog.dart';

/// Admin decision dashboard: `analytics/global` (fast) + bounded `deals` query (detail).
class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  final AdminAnalyticsService _analytics = AdminAnalyticsService();

  /// Refreshed when the user taps “Retry” after receiving the admin custom claim.
  Future<bool> _adminGateFuture = AuthService.isAdmin();

  void _retryAdminGate() {
    setState(() {
      _adminGateFuture = AuthService.isAdmin();
    });
  }

  String _fmtKwd(num n) {
    if (n == n.roundToDouble()) return '${n.toStringAsFixed(0)} KWD';
    return '${n.toStringAsFixed(2)} KWD';
  }

  String _fmtPct(double? share) {
    if (share == null) return '—';
    return '${(share * 100).toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        title: Text(isAr ? 'لوحة القرارات' : 'Business dashboard'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: AppLocalizations.of(context)!.adminControlCenterTitle,
            icon: const Icon(Icons.dashboard_customize_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AdminControlCenterPage(),
                ),
              );
            },
          ),
          IconButton(
            tooltip: AppLocalizations.of(context)!.hybridSettingsTooltip,
            icon: const Icon(Icons.tune_outlined),
            onPressed: () => showHybridMarketingSettingsDialog(context: context),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context)!.instagramPostAppBarTooltip,
            icon: const Icon(Icons.image_outlined),
            onPressed: () => showAdminInstagramPostGenerator(context),
          ),
        ],
      ),
      body: FutureBuilder<bool>(
        future: _adminGateFuture,
        builder: (context, adminSnap) {
          if (adminSnap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (adminSnap.data != true) {
            return _AdminAnalyticsAccessDenied(
              isAr: isAr,
              onRetry: _retryAdminGate,
            );
          }
          return _DashboardStreams(
            analytics: _analytics,
            fmtKwd: _fmtKwd,
            fmtPct: _fmtPct,
            isAr: isAr,
          );
        },
      ),
    );
  }
}

/// Firestore rules require [request.auth.token.admin == true] for `analytics/global`, `deals`, etc.
class _AdminAnalyticsAccessDenied extends StatelessWidget {
  const _AdminAnalyticsAccessDenied({
    required this.isAr,
    required this.onRetry,
  });

  final bool isAr;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 48, color: Colors.grey.shade600),
              const SizedBox(height: 16),
              Text(
                isAr ? 'لا يمكن تحميل التحليلات' : 'Analytics unavailable',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                isAr
                    ? 'هذه البيانات محمية بقواعد Firestore: يلزم صلاحية admin على حسابك (Custom Claim). اطلب من مسؤول المشروع تعيينها ثم سجّل الخروج وأعد الدخول لتحديث التوكن.'
                    : 'This data is protected: your account needs the Firebase `admin` custom claim. Ask a project owner to set it, then sign out and sign back in to refresh your ID token.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  height: 1.4,
                  color: Colors.grey.shade800,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onRetry,
                child: Text(isAr ? 'إعادة المحاولة' : 'Retry after sign-in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardStreams extends StatefulWidget {
  const _DashboardStreams({
    required this.analytics,
    required this.fmtKwd,
    required this.fmtPct,
    required this.isAr,
  });

  final AdminAnalyticsService analytics;
  final String Function(num n) fmtKwd;
  final String Function(double? share) fmtPct;
  final bool isAr;

  @override
  State<_DashboardStreams> createState() => _DashboardStreamsState();
}

class _DashboardStreamsState extends State<_DashboardStreams> {
  DealsTimeGrouping _timeGrouping = DealsTimeGrouping.month;

  static String _firestoreErrorMessage(Object? error, bool isAr) {
    final s = error?.toString() ?? '';
    if (s.contains('permission-denied') ||
        s.contains('Missing or insufficient permissions')) {
      return isAr
          ? 'رفض Firestore: تحقق من صلاحية admin ثم سجّل الخروج وأعد الدخول.'
          : 'Firestore permission denied: ensure your user has the admin custom claim, then sign out and back in.';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    return StreamBuilder<GlobalAnalyticsSnapshot>(
        stream: widget.analytics.watchGlobalAnalytics(),
        builder: (context, globalSnap) {
          if (globalSnap.hasError) {
            return _ErrorState(
              message: _firestoreErrorMessage(globalSnap.error, isAr),
            );
          }

          final globalLoading =
              globalSnap.connectionState == ConnectionState.waiting &&
              !globalSnap.hasData;

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: widget.analytics.watchDealsForDashboard(),
            builder: (context, dealsSnap) {
              if (dealsSnap.hasError) {
                return _ErrorState(
                  message: _firestoreErrorMessage(dealsSnap.error, isAr),
                );
              }

              final dealsLoading =
                  dealsSnap.connectionState == ConnectionState.waiting &&
                  !dealsSnap.hasData;

              final global = globalSnap.data ?? GlobalAnalyticsSnapshot.empty();

              final docs = dealsSnap.data?.docs ?? const [];

              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: widget.analytics.watchViewsForDashboard(),
                builder: (context, viewsSnap) {
                  if (viewsSnap.hasError) {
                    return _ErrorState(
                      message: _firestoreErrorMessage(viewsSnap.error, isAr),
                    );
                  }

                  final viewsLoading =
                      viewsSnap.connectionState == ConnectionState.waiting &&
                      !viewsSnap.hasData;

                  final viewDocs = viewsSnap.data?.docs ?? const [];

                  final bySource = AdminAnalyticsService.getDealsBySource(docs);
                  final byTime = AdminAnalyticsService.getDealsOverTime(
                    docs,
                    _timeGrouping,
                  );
                  final byArea = AdminAnalyticsService.getDealsByArea(
                    docs,
                    topN: 5,
                  );
                  final byType = AdminAnalyticsService.getDealsByPropertyType(
                    docs,
                  );

                  // Prefer deal-derived totals in detail table; global still authoritative for cards when deals sample empty.
                  final aiPctFromGlobal = global.aiDealShare;

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      if (globalLoading || dealsLoading || viewsLoading)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: LinearProgressIndicator(minHeight: 3),
                        ),

                      // --- Section 1: executive metrics (analytics/global) ---
                      _SectionTitle(
                        isAr ? 'مؤشرات رئيسية' : 'Top metrics',
                        subtitle: isAr
                            ? 'من مستند التجميع السريع'
                            : 'From analytics/global',
                      ),
                      const SizedBox(height: 10),
                      LayoutBuilder(
                        builder: (context, c) {
                          final wide = c.maxWidth > 560;
                          final m1 = _MetricCard(
                            label: isAr ? 'إجمالي الصفقات' : 'Total deals',
                            value: '${global.totalDeals.round()}',
                            icon: Icons.handshake_outlined,
                          );
                          final m2 = _MetricCard(
                            label: isAr ? 'حجم التداول' : 'Total volume',
                            value: widget.fmtKwd(global.totalVolume),
                            icon: Icons.payments_outlined,
                          );
                          final m3 = _MetricCard(
                            label: isAr ? 'إجمالي العمولة' : 'Total commission',
                            value: widget.fmtKwd(global.totalCommission),
                            icon: Icons.account_balance_wallet_outlined,
                          );
                          final m4 = _MetricCard(
                            label: isAr
                                ? 'نسبة صفقات الذكاء الاصطناعي'
                                : 'AI deals share',
                            value: widget.fmtPct(aiPctFromGlobal),
                            icon: Icons.smart_toy_outlined,
                            foot: 'aiDeals ÷ totalDeals',
                          );
                          if (wide) {
                            return Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(child: m1),
                                    const SizedBox(width: 12),
                                    Expanded(child: m2),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(child: m3),
                                    const SizedBox(width: 12),
                                    Expanded(child: m4),
                                  ],
                                ),
                              ],
                            );
                          }
                          return Column(
                            children: [
                              m1,
                              const SizedBox(height: 10),
                              m2,
                              const SizedBox(height: 10),
                              m3,
                              const SizedBox(height: 10),
                              m4,
                            ],
                          );
                        },
                      ),

                      const SizedBox(height: 16),
                      AdminCaptionPerformanceSection(isAr: isAr),
                      const SizedBox(height: 16),
                      AdminCaptionLearningSection(isAr: isAr),
                      const SizedBox(height: 16),
                      AdminDecisionAccuracySection(isAr: isAr),
                      const SizedBox(height: 16),
                      Builder(
                        builder: (ctx) {
                          // Decision engine: today vs yesterday AI share, conversion sample, deal counts — no extra queries.
                          final day =
                              AdminIntelligenceService.buildDaySampleMetrics(
                            deals: docs,
                            views: viewDocs,
                          );
                          final recommendations =
                              AdminRecommendationsService.generateRecommendations(
                            day: day,
                            totalDealsGlobal: global.totalDeals.round(),
                            dealDocs: docs,
                            viewDocs: viewDocs,
                            context: ctx,
                            isAr: isAr,
                          );
                          return buildRecommendationsSection(
                            recommendations,
                            isAr: isAr,
                          );
                        },
                      ),

                      const SizedBox(height: 8),
                      _Footnote(
                        isAr
                            ? 'آخر ${AdminAnalyticsService.kDashboardDealsLimit} صفقة و ${AdminAnalyticsService.kDashboardViewsLimit} مشاهدة للذكاء والتحويل.'
                            : 'Intelligence uses latest ${AdminAnalyticsService.kDashboardDealsLimit} deals + ${AdminAnalyticsService.kDashboardViewsLimit} views.',
                      ),

                      const SizedBox(height: 20),
                      AdminNotificationPerformanceSection(
                        analytics: widget.analytics,
                        isAr: isAr,
                      ),

                      const SizedBox(height: 24),

                      // --- Intelligence: conversion, insights, alerts ---
                      _IntelligenceBlock(
                        global: global,
                        dealDocs: docs,
                        viewDocs: viewDocs,
                        isAr: isAr,
                      ),

                      const SizedBox(height: 28),

                      // --- Section 2: source breakdown (deals) ---
                      _SectionTitle(
                        isAr ? 'تفصيل حسب المصدر' : 'Source breakdown',
                        subtitle: isAr
                            ? 'من مجموعة الصفقات (إيراد = السعر النهائي)'
                            : 'From deals (revenue = final price)',
                      ),
                      const SizedBox(height: 10),
                      if (docs.isEmpty && !dealsLoading)
                        _EmptyHint(isAr: isAr)
                      else
                        _SourceBreakdownTable(
                          rows: bySource,
                          fmtKwd: widget.fmtKwd,
                          isAr: isAr,
                        ),

                      const SizedBox(height: 28),

                      // --- Section 3: deals over time ---
                      _SectionTitle(
                        isAr ? 'الصفقات عبر الزمن' : 'Deals over time',
                        subtitle: isAr ? 'حسب تاريخ الإغلاق' : 'By closedAt',
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: SegmentedButton<DealsTimeGrouping>(
                          segments: [
                            ButtonSegment(
                              value: DealsTimeGrouping.day,
                              label: Text(isAr ? 'يوم' : 'Day'),
                            ),
                            ButtonSegment(
                              value: DealsTimeGrouping.week,
                              label: Text(isAr ? 'أسبوع' : 'Week'),
                            ),
                            ButtonSegment(
                              value: DealsTimeGrouping.month,
                              label: Text(isAr ? 'شهر' : 'Month'),
                            ),
                          ],
                          selected: {_timeGrouping},
                          onSelectionChanged: (s) {
                            setState(() => _timeGrouping = s.first);
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _DealsOverTimeChart(stats: byTime, isAr: isAr),

                      const SizedBox(height: 28),

                      // --- Section 4: top areas ---
                      _SectionTitle(
                        isAr ? 'أبرز المناطق' : 'Top areas',
                        subtitle: isAr
                            ? 'محافظة + منطقة (أعلى 5 حسب الإيراد)'
                            : 'Governorate + area (top 5 by revenue)',
                      ),
                      const SizedBox(height: 10),
                      if (byArea.isEmpty && docs.isNotEmpty)
                        Text(
                          isAr
                              ? 'لا توجد بيانات منطقة'
                              : 'No area fields on sample',
                          style: TextStyle(color: Colors.grey.shade600),
                        )
                      else if (docs.isEmpty && !dealsLoading)
                        _EmptyHint(isAr: isAr)
                      else
                        ...byArea.map(
                          (a) =>
                              _AreaTile(
                                  stats: a, fmtKwd: widget.fmtKwd, isAr: isAr),
                        ),

                      const SizedBox(height: 28),

                      // --- Section 5: property types ---
                      _SectionTitle(
                        isAr ? 'أنواع العقار' : 'Property types',
                        subtitle: isAr
                            ? 'عدد الصفقات لكل نوع (العينة)'
                            : 'Deal count per type (sample)',
                      ),
                      const SizedBox(height: 10),
                      if (docs.isEmpty && !dealsLoading)
                        _EmptyHint(isAr: isAr)
                      else
                        ...byType.map(
                          (t) => _TypeBar(
                            label: t.propertyType,
                            count: t.count,
                            maxCount: byType.isEmpty
                                ? 1
                                : byType.map((e) => e.count).reduce(math.max),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          );
        },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ],
    );
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.red),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.isAr});

  final bool isAr;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          isAr ? 'لا توجد صفقات في العينة.' : 'No deals in sample yet.',
          style: TextStyle(color: Colors.grey.shade700),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    this.foot,
  });

  final String label;
  final String value;
  final IconData icon;
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
            Icon(icon, color: AppColors.navy, size: 24),
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            if (foot != null) ...[
              const SizedBox(height: 4),
              Text(
                foot!,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourceBreakdownTable extends StatelessWidget {
  const _SourceBreakdownTable({
    required this.rows,
    required this.fmtKwd,
    required this.isAr,
  });

  final List<SourceStats> rows;
  final String Function(num) fmtKwd;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(
            AppColors.navy.withValues(alpha: 0.06),
          ),
          columns: [
            DataColumn(
              label: Text(
                isAr ? 'المصدر' : 'Source',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            DataColumn(
              label: Text(
                isAr ? 'الصفقات' : 'Deals',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            DataColumn(
              label: Text(
                isAr ? 'الإيراد' : 'Revenue',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            DataColumn(
              label: Text(
                isAr ? 'العمولة' : 'Commission',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
          rows: rows
              .map(
                (r) => DataRow(
                  cells: [
                    DataCell(Text(isAr ? r.displayLabelAr : r.displayLabel)),
                    DataCell(Text('${r.dealCount}')),
                    DataCell(Text(fmtKwd(r.totalRevenue))),
                    DataCell(Text(fmtKwd(r.totalCommission))),
                  ],
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

/// Line chart: deal count per time bucket (Section 3).
class _DealsOverTimeChart extends StatelessWidget {
  const _DealsOverTimeChart({required this.stats, required this.isAr});

  final List<TimeStats> stats;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            isAr
                ? 'لا توجد صفقات بتاريخ إغلاق في العينة.'
                : 'No deals with closedAt in sample.',
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      );
    }

    final spots = <FlSpot>[];
    for (var i = 0; i < stats.length; i++) {
      spots.add(FlSpot(i.toDouble(), stats[i].dealCount.toDouble()));
    }

    final maxCount = stats.map((e) => e.dealCount).reduce(math.max);
    final maxY = math.max(maxCount.toDouble(), 1) * 1.15;

    final labelEvery = stats.length > 14 ? (stats.length / 7).ceil() : 1;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 20, 20, 12),
        child: SizedBox(
          height: 240,
          child: LineChart(
            LineChartData(
              minX: 0,
              // Single bucket: widen domain so the line renders visibly.
              maxX: stats.length <= 1 ? 1 : (stats.length - 1).toDouble(),
              minY: 0,
              maxY: maxY,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: maxY > 5 ? maxY / 5 : 1,
                getDrawingHorizontalLine: (v) =>
                    FlLine(color: Colors.grey.shade200, strokeWidth: 1),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    interval: maxY > 5 ? maxY / 5 : 1,
                    getTitlesWidget: (v, m) => Text(
                      v.round().toString(),
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
                      if (i < 0 || i >= stats.length) {
                        return const SizedBox.shrink();
                      }
                      if (i % labelEvery != 0 && i != stats.length - 1) {
                        return const SizedBox.shrink();
                      }
                      final lb = stats[i].label;
                      final short = lb.length > 8
                          ? '${lb.substring(0, 7)}…'
                          : lb;
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          short,
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
                  color: AppColors.navy,
                  barWidth: 3,
                  dotData: const FlDotData(show: true),
                  belowBarData: BarAreaData(
                    show: true,
                    color: AppColors.navy.withValues(alpha: 0.08),
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
                      if (i < 0 || i >= stats.length) continue;
                      final s = stats[i];
                      out.add(
                        LineTooltipItem(
                          '${s.label}\n${s.dealCount} deals\n${s.totalRevenue.toStringAsFixed(0)} KWD',
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

class _AreaTile extends StatelessWidget {
  const _AreaTile({
    required this.stats,
    required this.fmtKwd,
    required this.isAr,
  });

  final AreaStats stats;
  final String Function(num) fmtKwd;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        title: Text(
          stats.compositeLabel.isEmpty ? '—' : stats.compositeLabel,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          isAr
              ? '${stats.dealCount} صفقة · ${fmtKwd(stats.totalRevenue)}'
              : '${stats.dealCount} deals · ${fmtKwd(stats.totalRevenue)}',
        ),
        leading: CircleAvatar(
          backgroundColor: AppColors.navy.withValues(alpha: 0.1),
          child: const Icon(
            Icons.place_outlined,
            color: AppColors.navy,
            size: 20,
          ),
        ),
      ),
    );
  }
}

class _TypeBar extends StatelessWidget {
  const _TypeBar({
    required this.label,
    required this.count,
    required this.maxCount,
  });

  final String label;
  final int count;
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final ratio = maxCount <= 0 ? 0.0 : count / maxCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                '$count',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Colors.grey.shade200,
              color: AppColors.navy,
            ),
          ),
        ],
      ),
    );
  }
}

/// Conversion + insights + alerts from streamed samples (no extra async work).
class _IntelligenceBlock extends StatelessWidget {
  const _IntelligenceBlock({
    required this.global,
    required this.dealDocs,
    required this.viewDocs,
    required this.isAr,
  });

  final GlobalAnalyticsSnapshot global;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> viewDocs;
  final bool isAr;

  static String _fmtConv(double r) => '${(r * 100).toStringAsFixed(2)}%';

  static bool _isPositiveInsight(String en) {
    return en.contains('strongly') || en.contains('High conversion');
  }

  static String _sourceLabel(String key, bool isAr) {
    if (isAr) {
      switch (key) {
        case DealLeadSource.aiChat:
          return 'الذكاء الاصطناعي';
        case DealLeadSource.search:
          return 'بحث';
        case DealLeadSource.featured:
          return 'مميز';
        case DealLeadSource.direct:
          return 'مباشر';
        default:
          return 'غير معروف';
      }
    }
    switch (key) {
      case DealLeadSource.aiChat:
        return 'AI chat';
      case DealLeadSource.search:
        return 'Search';
      case DealLeadSource.featured:
        return 'Featured';
      case DealLeadSource.direct:
        return 'Direct';
      default:
        return 'Unknown';
    }
  }

  static String? _intelAr(String en) {
    const m = {
      'No closed deals yet — metrics will appear after your first approvals.':
          'لا توجد صفقات مغلقة بعد — تظهر المؤشرات بعد أول اعتمادات.',
      'AI is performing strongly': 'أداء قوي للذكاء الاصطناعي',
      'AI needs optimization': 'الذكاء الاصطناعي يحتاج تحسيناً',
      'Low conversion rate — improve listings':
          'معدل تحويل منخفض — حسّن الإعلانات',
      'High conversion performance': 'أداء تحويل مرتفع',
      '🚨 No deals recorded today': '🚨 لا صفقات مسجّلة اليوم',
      '📉 Deals dropped compared to yesterday': '📉 انخفاض الصفقات مقارنة بأمس',
      '📉 AI performance dropped': '📉 تراجع أداء الذكاء الاصطناعي',
      '📉 Conversion rate dropped vs yesterday':
          '📉 انخفاض معدل التحويل عن أمس',
    };
    return m[en];
  }

  @override
  Widget build(BuildContext context) {
    final totalDealsGlobal = global.totalDeals.round();
    final viewN = viewDocs.length;
    // Headline: global closed deals vs recent view sample (documented in subtitle).
    final overallConv = AdminIntelligenceService.calculateConversion(
      viewN,
      totalDealsGlobal,
    );
    final aiPct = global.aiDealShare ?? 0.0;

    final insights = AdminIntelligenceService.generateInsights(
      totalDeals: totalDealsGlobal,
      aiPercentage: aiPct,
      conversionRate: overallConv,
    );

    final day = AdminIntelligenceService.buildDaySampleMetrics(
      deals: dealDocs,
      views: viewDocs,
    );

    final alerts = AdminIntelligenceService.generateAlerts(
      todayDeals: day.todayDeals,
      yesterdayDeals: day.yesterdayDeals,
      todayAiPercentage: day.todayAiShare,
      yesterdayAiPercentage: day.yesterdayAiShare,
      conversionToday: day.conversionTodaySample,
      conversionYesterday: day.conversionYesterdaySample,
    );

    final vHist = AdminIntelligenceService.countByLeadSource(viewDocs);
    final dHist = AdminIntelligenceService.countByLeadSource(dealDocs);
    final convBySrc = AdminIntelligenceService.calculateConversionBySource(
      dealDocs,
      viewDocs,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          isAr ? 'الذكاء التشغيلي' : 'Operational intelligence',
          subtitle: isAr
              ? 'تحويل، رؤى، وتنبيهات (عيّنة مشاهدات + عيّنة صفقات)'
              : 'Conversion, insights & alerts (views sample + deals sample)',
        ),
        const SizedBox(height: 10),

        // 1) Conversion card
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
                Row(
                  children: [
                    Icon(Icons.filter_alt_outlined, color: AppColors.navy),
                    const SizedBox(width: 8),
                    Text(
                      isAr ? 'معدل التحويل' : 'Conversion rate',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isAr
                      ? 'الصفقات (analytics) ÷ عيّنة المشاهدات الأخيرة'
                      : 'Deals (analytics/global) ÷ latest views sample',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 14),
                Text(
                  isAr
                      ? 'معدل التحويل: ${_fmtConv(overallConv)}'
                      : 'Conversion rate: ${_fmtConv(overallConv)}',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  isAr
                      ? 'صفقات: $totalDealsGlobal · مشاهدات (عينة): $viewN'
                      : 'Deals: $totalDealsGlobal · Views (sample): $viewN',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                ),
                const Divider(height: 20),
                Text(
                  isAr
                      ? 'تحويل العينة حسب المصدر في الجدول أدناه (صفقات/مشاهدات ضمن نفس العيّنتين).'
                      : 'Per-source table uses the same two samples (deals ÷ views per channel).',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 14),

        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(
                AppColors.navy.withValues(alpha: 0.06),
              ),
              columns: [
                DataColumn(
                  label: Text(
                    isAr ? 'المصدر' : 'Source',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                DataColumn(
                  numeric: true,
                  label: Text(
                    isAr ? 'مشاهدات' : 'Views',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                DataColumn(
                  numeric: true,
                  label: Text(
                    isAr ? 'صفقات' : 'Deals',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                DataColumn(
                  numeric: true,
                  label: Text(
                    isAr ? 'تحويل' : 'Conv.',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
              rows: [
                for (final s in AdminIntelligenceService.canonicalSources)
                  DataRow(
                    cells: [
                      DataCell(Text(_sourceLabel(s, isAr))),
                      DataCell(Text('${vHist[s] ?? 0}')),
                      DataCell(Text('${dHist[s] ?? 0}')),
                      DataCell(Text(_fmtConv(convBySrc[s] ?? 0))),
                    ],
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),

        Text(
          isAr ? 'رؤى' : 'Insights',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 8),
        ...insights.map((en) {
          final text = isAr ? (_intelAr(en) ?? en) : en;
          final positive = _isPositiveInsight(en);
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            elevation: 0,
            color: positive ? Colors.green.shade50 : Colors.blue.shade50,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: positive ? Colors.green.shade200 : Colors.blue.shade100,
              ),
            ),
            child: ListTile(
              leading: Icon(
                positive ? Icons.trending_up : Icons.lightbulb_outline,
                color: positive ? Colors.green.shade800 : Colors.blue.shade800,
              ),
              title: Text('💡 $text'),
            ),
          );
        }),

        const SizedBox(height: 12),

        Text(
          isAr ? 'تنبيهات' : 'Alerts',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 8),
        if (alerts.isEmpty)
          Text(
            isAr ? 'لا تنبيهات حالياً.' : 'No active alerts.',
            style: TextStyle(color: Colors.grey.shade600),
          )
        else
          ...alerts.map((line) {
            final text = isAr ? (_intelAr(line) ?? line) : line;
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              elevation: 0,
              color: Colors.red.shade50,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.red.shade200),
              ),
              child: ListTile(
                leading: Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.red.shade800,
                ),
                title: Text(
                  text,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            );
          }),
      ],
    );
  }
}
