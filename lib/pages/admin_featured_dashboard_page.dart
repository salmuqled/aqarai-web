import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/featured_ads_dashboard_service.dart';

class AdminFeaturedDashboardPage extends StatefulWidget {
  const AdminFeaturedDashboardPage({super.key});

  @override
  State<AdminFeaturedDashboardPage> createState() =>
      _AdminFeaturedDashboardPageState();
}

class _AdminFeaturedDashboardPageState extends State<AdminFeaturedDashboardPage> {
  Future<bool> _adminGateFuture = AuthService.isAdmin();
  final FeaturedAdsDashboardService _svc = FeaturedAdsDashboardService();

  FeaturedDashboardWindow _window = FeaturedDashboardWindow.d7;

  void _retryAdminGate() => setState(() => _adminGateFuture = AuthService.isAdmin());

  static String _pct(double? r) {
    if (r == null) return '—';
    return '${(r * 100).clamp(0, 999).toStringAsFixed(1)}%';
  }

  static String _kwd(num n) {
    final v = (n.toDouble() * 1000).roundToDouble() / 1000;
    if (v == v.roundToDouble()) return '${v.toStringAsFixed(0)} KWD';
    return '${v.toStringAsFixed(2)} KWD';
  }

  String _windowLabel(BuildContext context, FeaturedDashboardWindow w) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    switch (w) {
      case FeaturedDashboardWindow.h24:
        return isAr ? 'آخر ٢٤ ساعة' : 'Last 24h';
      case FeaturedDashboardWindow.d7:
        return isAr ? 'آخر ٧ أيام' : 'Last 7 days';
      case FeaturedDashboardWindow.d30:
        return isAr ? 'آخر ٣٠ يوم' : 'Last 30 days';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return FutureBuilder<bool>(
      future: _adminGateFuture,
      builder: (context, adminSnap) {
        if (adminSnap.connectionState == ConnectionState.waiting) {
          return Scaffold(
            backgroundColor: const Color(0xFFF7F7F7),
            appBar: AppBar(title: Text(isAr ? 'لوحة تمييز الإعلانات' : 'Featured ads dashboard')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (adminSnap.data != true) {
          return Scaffold(
            backgroundColor: const Color(0xFFF7F7F7),
            appBar: AppBar(title: Text(isAr ? 'لوحة تمييز الإعلانات' : 'Featured ads dashboard')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_outline, size: 48, color: Colors.grey.shade600),
                      const SizedBox(height: 12),
                      Text(
                        isAr ? 'لا يمكن تحميل الصفحة' : 'Access denied',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        isAr
                            ? 'هذه البيانات محمية وتتطلب صلاحية admin.'
                            : 'This page requires Firebase admin custom claim.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade800, height: 1.35),
                      ),
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _retryAdminGate,
                        child: Text(isAr ? 'إعادة المحاولة' : 'Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final future = _svc.load(window: _window);

        return Scaffold(
          backgroundColor: const Color(0xFFF7F7F7),
          appBar: AppBar(
            title: Text(isAr ? 'لوحة تمييز الإعلانات' : 'Featured ads dashboard'),
            centerTitle: true,
            actions: [
              DropdownButtonHideUnderline(
                child: DropdownButton<FeaturedDashboardWindow>(
                  value: _window,
                  borderRadius: BorderRadius.circular(12),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _window = v);
                  },
                  items: FeaturedDashboardWindow.values
                      .map(
                        (w) => DropdownMenuItem(
                          value: w,
                          child: Text(_windowLabel(context, w)),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: FutureBuilder<FeaturedAdsDashboardSnapshot>(
            future: future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '${isAr ? 'تعذر تحميل التحليلات' : 'Failed to load analytics'}: ${snap.error}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.red.shade800),
                    ),
                  ),
                );
              }

              final d = snap.data!;

              final insights = _buildInsights(d, isAr: isAr);

              Widget card({
                required String title,
                required String value,
                required IconData icon,
                String? foot,
              }) {
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
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 22, color: AppColors.navy),
                        const SizedBox(height: 6),
                        Text(
                          title,
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        FittedBox(
                          alignment: AlignmentDirectional.centerStart,
                          fit: BoxFit.scaleDown,
                          child: Text(
                            value,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: AppColors.navy,
                            ),
                            maxLines: 1,
                          ),
                        ),
                        if (foot != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            foot,
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }

              final mostPlan = d.mostPopularPlanDays == null
                  ? '—'
                  : '${d.mostPopularPlanDays} ${isAr ? 'يوم' : 'days'}';

              final cards = <Widget>[
                card(
                  title: isAr ? 'إجمالي الإيراد' : 'Total revenue',
                  value: _kwd(d.totalRevenueKwd),
                  icon: Icons.payments_outlined,
                ),
                card(
                  title: isAr ? 'إجمالي المشتريات' : 'Total purchases',
                  value: '${d.totalPurchases}',
                  icon: Icons.receipt_long_outlined,
                ),
                card(
                  title: isAr ? 'متوسط الإيراد لكل مستخدم' : 'Avg revenue per user',
                  value: _kwd(d.avgRevenuePerUserKwd),
                  icon: Icons.groups_2_outlined,
                  foot: isAr ? 'الإيراد ÷ المشترين' : 'revenue ÷ unique buyers',
                ),
                card(
                  title: isAr ? 'الخطة الأكثر شيوعاً' : 'Most popular plan',
                  value: mostPlan,
                  icon: Icons.star_outline,
                ),
                card(
                  title: isAr ? 'CTR (AI)' : 'CTR (AI)',
                  value: _pct(d.ctr),
                  icon: Icons.percent_outlined,
                  foot: 'clicked ÷ shown',
                ),
                card(
                  title: isAr ? 'نسبة التحويل (AI)' : 'Conversion (AI)',
                  value: _pct(d.conversionRate),
                  icon: Icons.trending_up_outlined,
                  foot: 'paid ÷ clicked',
                ),
                card(
                  title: isAr ? 'إيراد AI' : 'AI-generated revenue',
                  value: _kwd(d.aiRevenueKwd),
                  icon: Icons.smart_toy_outlined,
                ),
                card(
                  title: isAr ? 'إيراد لكل ظهور' : 'Revenue per suggestion',
                  value: _kwd(d.revenuePerSuggestionKwd),
                  icon: Icons.account_balance_wallet_outlined,
                  foot: isAr ? 'إيراد AI ÷ الظهور' : 'AI revenue ÷ shown',
                ),
              ];

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LayoutBuilder(
                      builder: (context, c) {
                        final wide = c.maxWidth >= 900;
                        final cross = wide ? 4 : 2;
                        // Taller cells than width/2.2 — Arabic labels + foot lines need room
                        // or GridView clips and shows yellow/black overflow stripes.
                        return GridView.count(
                          crossAxisCount: cross,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          childAspectRatio: wide ? 1.52 : 1.28,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          children: cards,
                        );
                      },
                    ),
                    const SizedBox(height: 16),

                    _SectionTitle(title: isAr ? 'Insights' : 'Insights'),
                    const SizedBox(height: 10),
                    if (insights.isEmpty)
                      Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: Colors.grey.shade200),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            isAr
                                ? 'لا توجد توصيات حالياً — اجمع بيانات أكثر ضمن الفترة.'
                                : 'No insights yet — collect more data in this window.',
                            style: TextStyle(color: Colors.grey.shade700, height: 1.35),
                          ),
                        ),
                      )
                    else
                      Column(
                        children: [
                          for (final x in insights)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _InsightCard(insight: x, isAr: isAr),
                            ),
                        ],
                      ),
                    const SizedBox(height: 16),

                    _SectionTitle(title: isAr ? 'الإيراد عبر الزمن' : 'Revenue over time'),
                    const SizedBox(height: 10),
                    _RevenueLineChart(series: d.revenueSeries),
                    const SizedBox(height: 16),

                    _SectionTitle(title: isAr ? 'توزيع الخطط' : 'Plans distribution'),
                    const SizedBox(height: 10),
                    _PlansBarChart(counts: d.plansCounts),
                    const SizedBox(height: 16),

                    _SectionTitle(title: isAr ? 'قمع التحويل (AI)' : 'AI conversion funnel'),
                    const SizedBox(height: 10),
                    _FunnelCard(
                      shown: d.totalShown,
                      clicked: d.totalClicked,
                      paid: d.totalConversions,
                      isAr: isAr,
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

List<_Insight> _buildInsights(
  FeaturedAdsDashboardSnapshot d, {
  required bool isAr,
}) {
  final out = <_Insight>[];

  final ctr = d.ctr;
  final conv = d.conversionRate;
  final revPerShown = d.revenuePerSuggestionKwd;

  // Plan dominance.
  final totalPlans = d.plansCounts.values.fold<int>(0, (a, b) => a + b);
  int? topPlan;
  var topCount = 0;
  for (final e in d.plansCounts.entries) {
    if (e.value > topCount) {
      topCount = e.value;
      topPlan = e.key;
    }
  }
  final dominance = totalPlans <= 0 ? null : topCount / totalPlans;

  // 1) CTR weak
  if (ctr != null && d.totalShown >= 25 && ctr < 0.10) {
    out.add(
      _Insight(
        severity: _InsightSeverity.warning,
        icon: Icons.text_fields_outlined,
        title: isAr ? 'CTR منخفض' : 'Low CTR',
        body: isAr
            ? 'معدل النقر أقل من 10%. غالباً رسالة الاقتراح غير مقنعة — جرّب نص أقوى، ذكر رقم المشاهدات، واختصر الرسالة.'
            : 'CTR is under 10%. The suggestion message is likely weak — try stronger copy, mention views, and reduce friction.',
      ),
    );
  }

  // 2) High CTR but low conversion
  if (ctr != null &&
      conv != null &&
      d.totalClicked >= 15 &&
      ctr >= 0.12 &&
      conv < 0.15) {
    out.add(
      _Insight(
        severity: _InsightSeverity.critical,
        icon: Icons.payments_outlined,
        title: isAr ? 'اهتمام عالي… تحويل ضعيف' : 'High interest, low conversion',
        body: isAr
            ? 'المستخدمون ينقرون لكن لا يكملون الدفع. راجع تسعير الخطط أو تجربة الدفع (خطوات كثيرة/أخطاء/بطء).'
            : 'Users click but don’t complete payment. Review pricing and payment UX (too many steps, errors, slow flow).',
      ),
    );
  }

  // 3) Revenue per suggestion low
  if (d.totalShown >= 50 && revPerShown > 0 && revPerShown < 0.25) {
    out.add(
      _Insight(
        severity: _InsightSeverity.warning,
        icon: Icons.filter_alt_outlined,
        title: isAr ? 'العائد لكل ظهور منخفض' : 'Low revenue per suggestion',
        body: isAr
            ? 'جرّب استهداف اقتراحات التمييز فقط للعقارات الأعلى قيمة أو التي لديها نية شراء أعلى (مشاهدات كثيرة بدون استفسارات).'
            : 'Consider targeting suggestions only to higher-value / higher-intent properties (high views with no inquiries).',
      ),
    );
  }

  // 4) Plan dominates
  if (topPlan != null && dominance != null && totalPlans >= 12 && dominance >= 0.65) {
    out.add(
      _Insight(
        severity: _InsightSeverity.info,
        icon: Icons.star_border_outlined,
        title: isAr ? 'خطة مهيمنة' : 'One plan dominates',
        body: isAr
            ? 'خطة $topPlan يوم تمثل ${(dominance * 100).toStringAsFixed(0)}% من المشتريات. أبرزها كخيار “موصى به” وركّز عليها في الاقتراحات.'
            : 'The $topPlan-day plan is ${(dominance * 100).toStringAsFixed(0)}% of purchases. Promote it as “recommended” and lean into it in suggestions.',
      ),
    );
  }

  // 5) Strong performance: keep pushing
  if (ctr != null &&
      conv != null &&
      d.totalShown >= 50 &&
      ctr >= 0.15 &&
      conv >= 0.20) {
    out.add(
      _Insight(
        severity: _InsightSeverity.success,
        icon: Icons.rocket_launch_outlined,
        title: isAr ? 'الأداء ممتاز' : 'Great performance',
        body: isAr
            ? 'CTR والتحويل قويين. جرّب زيادة ظهور الاقتراحات (رفع العتبات) أو إضافة تذكير قبل انتهاء التمييز.'
            : 'CTR and conversion are strong. Consider increasing suggestion coverage or adding an “ending soon” reminder.',
      ),
    );
  }

  // Keep 3–5 max, highest severity first.
  out.sort((a, b) => b.severity.index.compareTo(a.severity.index));
  if (out.length > 5) return out.sublist(0, 5);
  return out;
}

enum _InsightSeverity { info, warning, critical, success }

class _Insight {
  const _Insight({
    required this.severity,
    required this.icon,
    required this.title,
    required this.body,
  });

  final _InsightSeverity severity;
  final IconData icon;
  final String title;
  final String body;
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({required this.insight, required this.isAr});

  final _Insight insight;
  final bool isAr;

  Color _accent() {
    switch (insight.severity) {
      case _InsightSeverity.info:
        return AppColors.navy;
      case _InsightSeverity.warning:
        return const Color(0xFFE65100);
      case _InsightSeverity.critical:
        return const Color(0xFFC62828);
      case _InsightSeverity.success:
        return const Color(0xFF2E7D32);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent();
    final bg = Color.alphaBlend(accent.withValues(alpha: 0.06), Colors.white);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: accent.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(insight.icon, color: accent.withValues(alpha: 0.95)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    insight.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: AppColors.navy,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    insight.body,
                    textAlign: isAr ? TextAlign.right : TextAlign.start,
                    style: TextStyle(
                      height: 1.35,
                      color: Colors.black.withValues(alpha: 0.78),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: AppColors.navy,
      ),
    );
  }
}

class _RevenueLineChart extends StatelessWidget {
  const _RevenueLineChart({required this.series});
  final List<RevenuePoint> series;

  @override
  Widget build(BuildContext context) {
    final points = <FlSpot>[];
    for (var i = 0; i < series.length; i++) {
      points.add(FlSpot(i.toDouble(), series[i].revenueKwd));
    }
    final maxY = points.isEmpty ? 1.0 : points.map((p) => p.y).reduce(math.max);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: SizedBox(
          height: 220,
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: (maxY * 1.15).clamp(1, double.infinity),
              gridData: FlGridData(show: true),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    interval: maxY <= 0 ? 1 : (maxY / 3).clamp(1, double.infinity),
                    getTitlesWidget: (v, meta) => Text(
                      v.toStringAsFixed(0),
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                    ),
                  ),
                ),
                bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: points.isEmpty ? const [FlSpot(0, 0)] : points,
                  isCurved: true,
                  color: AppColors.navy,
                  barWidth: 3,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: AppColors.navy.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlansBarChart extends StatelessWidget {
  const _PlansBarChart({required this.counts});
  final Map<int, int> counts;

  @override
  Widget build(BuildContext context) {
    const plans = <int>[3, 7, 14, 30];
    final maxY = counts.isEmpty ? 1.0 : counts.values.map((e) => e.toDouble()).reduce(math.max);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: SizedBox(
          height: 220,
          child: BarChart(
            BarChartData(
              maxY: (maxY * 1.2).clamp(1, double.infinity),
              gridData: FlGridData(show: true),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    interval: maxY <= 0 ? 1 : (maxY / 3).clamp(1, double.infinity),
                    getTitlesWidget: (v, meta) => Text(
                      v.toStringAsFixed(0),
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (v, meta) {
                      final idx = v.toInt();
                      if (idx < 0 || idx >= plans.length) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${plans[idx]}d',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade800),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < plans.length; i++)
                  BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: (counts[plans[i]] ?? 0).toDouble(),
                        color: AppColors.navy.withValues(alpha: 0.85),
                        width: 18,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FunnelCard extends StatelessWidget {
  const _FunnelCard({
    required this.shown,
    required this.clicked,
    required this.paid,
    required this.isAr,
  });

  final int shown;
  final int clicked;
  final int paid;
  final bool isAr;

  double? _rate(int a, int b) => b <= 0 ? null : a / b;

  String _pct(double? r) {
    if (r == null) return '—';
    return '${(r * 100).clamp(0, 999).toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final r1 = _rate(clicked, shown);
    final r2 = _rate(paid, clicked);

    Widget row(String label, int from, int to, double? rate) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '$from → $to',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '(${_pct(rate)})',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.teal.shade700,
                  ),
                ),
              ],
            ),
            if (rate != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  value: rate.clamp(0.0, 1.0),
                  minHeight: 7,
                  backgroundColor: Colors.grey.shade200,
                  color: AppColors.navy.withValues(alpha: 0.85),
                ),
              ),
            ],
          ],
        ),
      );
    }

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
            row(
              isAr ? 'الظهور → النقر' : 'Shown → Clicked',
              shown,
              clicked,
              r1,
            ),
            row(
              isAr ? 'النقر → الدفع' : 'Clicked → Paid',
              clicked,
              paid,
              r2,
            ),
          ],
        ),
      ),
    );
  }
}

