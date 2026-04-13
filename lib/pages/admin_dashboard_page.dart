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
import 'package:aqarai_app/pages/add_company_payment_page.dart';
import 'package:aqarai_app/pages/admin_chalet_payouts_page.dart';
import 'package:aqarai_app/pages/admin_auction_earnings_page.dart';
import 'package:aqarai_app/pages/admin_auction_requests_page.dart';
import 'package:aqarai_app/pages/admin_control_center_page.dart';
import 'package:aqarai_app/pages/admin_invoices_page.dart';
import 'package:aqarai_app/pages/admin_featured_dashboard_page.dart';
import 'package:aqarai_app/widgets/admin_cashflow_ledger_section.dart';
import 'package:aqarai_app/widgets/admin_commission_section.dart';
import 'package:aqarai_app/widgets/admin_outstanding_section.dart';
import 'package:aqarai_app/widgets/admin_priority_section.dart';
import 'package:aqarai_app/widgets/admin_conversion_section.dart';
import 'package:aqarai_app/widgets/admin_deal_pipeline_section.dart';
import 'package:aqarai_app/widgets/admin_followup_section.dart';
import 'package:aqarai_app/widgets/admin_analytics_section.dart';
import 'package:aqarai_app/widgets/admin_crm_snapshot_section.dart';
import 'package:aqarai_app/widgets/admin_leads_split_section.dart';
import 'package:aqarai_app/widgets/hybrid_marketing_settings_dialog.dart';
import 'package:aqarai_app/widgets/admin_ai_suggestions_analytics_section.dart';
import 'package:aqarai_app/widgets/admin_ai_suggestions_controls_section.dart';
import 'package:aqarai_app/widgets/admin_ai_config_history_section.dart';
import 'package:aqarai_app/widgets/admin_ai_config_rollback_banner.dart';
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

  /// Quick actions moved out of [AppBar] — same navigations as before.
  Widget _buildAdminDashboardQuickActionsBar(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    const gap = SizedBox(width: 12);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      primary: false,
      physics: const ClampingScrollPhysics(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: loc.adminChaletPayoutsTitle,
            icon: const Icon(Icons.payments_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AdminChaletPayoutsPage(),
                ),
              );
            },
          ),
          gap,
          IconButton(
            tooltip: loc.companyPaymentAddTitle,
            icon: const Icon(Icons.add_card_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AddCompanyPaymentPage(),
                ),
              );
            },
          ),
          gap,
          IconButton(
            tooltip: loc.adminInvoicesTitle,
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AdminInvoicesPage(),
                ),
              );
            },
          ),
          gap,
          IconButton(
            tooltip: loc.adminAuctionEarningsTitle,
            icon: const Icon(Icons.account_balance_wallet_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AdminAuctionEarningsPage(),
                ),
              );
            },
          ),
          gap,
          IconButton(
            tooltip: loc.adminAuctionRequestsTitle,
            icon: const Icon(Icons.gavel_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AdminAuctionRequestsPage(),
                ),
              );
            },
          ),
          gap,
          IconButton(
            tooltip: isAr ? 'تمييز الإعلانات' : 'Featured ads',
            icon: const Icon(Icons.star_border_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AdminFeaturedDashboardPage(),
                ),
              );
            },
          ),
          gap,
          IconButton(
            tooltip: loc.adminControlCenterTitle,
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
          gap,
          IconButton(
            tooltip: loc.hybridSettingsTooltip,
            icon: const Icon(Icons.tune_outlined),
            onPressed: () => showHybridMarketingSettingsDialog(context: context),
          ),
          gap,
          IconButton(
            tooltip: loc.instagramPostAppBarTooltip,
            icon: const Icon(Icons.image_outlined),
            onPressed: () => showAdminInstagramPostGenerator(context),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        title: Text(isAr ? 'لوحة القرارات' : 'Business dashboard'),
        centerTitle: true,
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: _buildAdminDashboardQuickActionsBar(context),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _DashboardStreams(
                  analytics: _analytics,
                  fmtKwd: _fmtKwd,
                  fmtPct: _fmtPct,
                  isAr: isAr,
                ),
              ),
            ],
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

  /// Stable stream instances — calling [watchDealsForDashboard] on every
  /// [build] creates new Firestore listeners; parent stream updates then
  /// cancel/re-subscribe inner streams (severe jank when scrolling / syncing).
  late final Stream<GlobalAnalyticsSnapshot> _globalStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _dealsStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _viewsStream;

  @override
  void initState() {
    super.initState();
    _globalStream = widget.analytics.watchGlobalAnalytics();
    _dealsStream = widget.analytics.watchDealsForDashboard();
    _viewsStream = widget.analytics.watchViewsForDashboard();
  }

  void _appendIntelligenceBlockSlivers(
    List<Widget> out, {
    required GlobalAnalyticsSnapshot global,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> viewDocs,
    required bool isAr,
  }) {
    void box(Widget child) => out.add(SliverToBoxAdapter(child: child));

    final totalDealsGlobal = global.totalDeals.round();
    final viewN = viewDocs.length;
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

    final sources = AdminIntelligenceService.canonicalSources;

    box(
      _SectionTitle(
        isAr ? 'الذكاء التشغيلي' : 'Operational intelligence',
        subtitle: isAr
            ? 'تحويل، رؤى، وتنبيهات (عيّنة مشاهدات + عيّنة صفقات)'
            : 'Conversion, insights & alerts (views sample + deals sample)',
      ),
    );
    box(const SizedBox(height: 10));

    box(
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
                    ? 'معدل التحويل: ${_IntelligenceUi.fmtConv(overallConv)}'
                    : 'Conversion rate: ${_IntelligenceUi.fmtConv(overallConv)}',
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
    );

    box(const SizedBox(height: 14));

    out.add(
      SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: RepaintBoundary(
              child: _IntelligenceConversionTableHeader(isAr: isAr),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (BuildContext c, int index) {
                final s = sources[index];
                return _IntelligenceConversionDataRow(
                  sourceLabel: _IntelligenceUi.sourceLabel(s, isAr),
                  views: '${vHist[s] ?? 0}',
                  deals: '${dHist[s] ?? 0}',
                  convLabel: _IntelligenceUi.fmtConv(convBySrc[s] ?? 0),
                  isLast: index == sources.length - 1,
                );
              },
              childCount: sources.length,
              addAutomaticKeepAlives: true,
              addRepaintBoundaries: true,
            ),
          ),
        ],
      ),
    );

    box(const SizedBox(height: 20));

    box(
      Text(
        isAr ? 'رؤى' : 'Insights',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: AppColors.navy,
        ),
      ),
    );
    box(const SizedBox(height: 8));
    for (final en in insights) {
      final text = isAr ? (_IntelligenceUi.intelAr(en) ?? en) : en;
      final positive = _IntelligenceUi.isPositiveInsight(en);
      box(
        Card(
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
        ),
      );
    }

    box(const SizedBox(height: 12));

    box(
      Text(
        isAr ? 'تنبيهات' : 'Alerts',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: AppColors.navy,
        ),
      ),
    );
    box(const SizedBox(height: 8));
    if (alerts.isEmpty) {
      box(
        Text(
          isAr ? 'لا تنبيهات حالياً.' : 'No active alerts.',
          style: TextStyle(color: Colors.grey.shade600),
        ),
      );
    } else {
      for (final line in alerts) {
        final text = isAr ? (_IntelligenceUi.intelAr(line) ?? line) : line;
        box(
          Card(
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
          ),
        );
      }
    }
  }

  /// Dashboard body as explicit slivers for [CustomScrollView]. Source breakdown
  /// rows use [SliverList] (true lazy) instead of a nested [ListView].
  List<Widget> _buildDashboardSlivers({
    required BuildContext context,
    required bool isAr,
    required bool showTopLoading,
    required GlobalAnalyticsSnapshot global,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> viewDocs,
    required List<SourceStats> bySource,
    required List<TimeStats> byTime,
    required List<AreaStats> byArea,
    required List<PropertyTypeStats> byType,
    required bool dealsLoading,
  }) {
    final fmtKwd = widget.fmtKwd;
    final fmtPct = widget.fmtPct;
    final analytics = widget.analytics;
    final aiPctFromGlobal = global.aiDealShare;
    final out = <Widget>[];

    void box(Widget child) => out.add(SliverToBoxAdapter(child: child));

    box(_AdminDashboardLoadingStrip(show: showTopLoading));

    box(
      _AdminDashboardExecutiveMetricsSection(
        isAr: isAr,
        global: global,
        fmtKwd: fmtKwd,
        fmtPct: fmtPct,
        aiPctFromGlobal: aiPctFromGlobal,
      ),
    );

    box(const SizedBox(height: 20));
    box(AdminDealPipelineSection(dealDocs: docs));
    box(const SizedBox(height: 20));
    box(AdminCrmSnapshotSection(dealDocs: docs, isAr: isAr));
    box(const SizedBox(height: 20));
    box(AdminAnalyticsSection(dealDocs: docs, isAr: isAr));
    box(const SizedBox(height: 20));
    box(AdminFollowupSection(dealDocs: docs));
    box(const SizedBox(height: 20));
    box(AdminLeadsSplitSection(dealDocs: docs));
    box(const SizedBox(height: 20));
    box(AdminConversionSection(dealDocs: docs));
    box(const SizedBox(height: 20));
    box(AdminAiConfigRollbackBanner(isAr: isAr));
    box(const SizedBox(height: 20));
    box(AdminAiSuggestionsControlsSection(isAr: isAr));
    box(const SizedBox(height: 20));
    box(AdminAiConfigHistorySection(isAr: isAr));
    box(const SizedBox(height: 20));
    box(const AdminAiSuggestionsAnalyticsSection());
    box(const SizedBox(height: 20));
    box(
      RepaintBoundary(
        child: AdminCommissionSection(dealDocs: docs, fmtKwd: fmtKwd),
      ),
    );
    box(const SizedBox(height: 20));
    box(AdminOutstandingSection(dealDocs: docs, fmtKwd: fmtKwd));
    box(const SizedBox(height: 20));
    box(AdminPrioritySection(dealDocs: docs, fmtKwd: fmtKwd));
    box(const SizedBox(height: 20));
    box(AdminCashflowLedgerSection(fmtKwd: fmtKwd, isAr: isAr));

    box(const SizedBox(height: 16));
    box(
      AdminCaptionPerformanceSection(
        key: const ValueKey<String>('adminCaptionPerformance'),
        isAr: isAr,
      ),
    );
    box(const SizedBox(height: 16));
    box(AdminCaptionLearningSection(isAr: isAr));
    box(const SizedBox(height: 16));
    box(AdminDecisionAccuracySection(isAr: isAr));
    box(const SizedBox(height: 16));
    box(
      Builder(
        builder: (ctx) {
          final day = AdminIntelligenceService.buildDaySampleMetrics(
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
          return buildRecommendationsSection(recommendations, isAr: isAr);
        },
      ),
    );

    box(const SizedBox(height: 8));
    box(
      _Footnote(
        isAr
            ? 'آخر ${AdminAnalyticsService.kDashboardDealsLimit} صفقة و ${AdminAnalyticsService.kDashboardViewsLimit} مشاهدة للذكاء والتحويل.'
            : 'Intelligence uses latest ${AdminAnalyticsService.kDashboardDealsLimit} deals + ${AdminAnalyticsService.kDashboardViewsLimit} views.',
      ),
    );

    box(const SizedBox(height: 20));
    box(
      AdminNotificationPerformanceSection(
        analytics: analytics,
        isAr: isAr,
      ),
    );

    box(const SizedBox(height: 24));
    _appendIntelligenceBlockSlivers(
      out,
      global: global,
      dealDocs: docs,
      viewDocs: viewDocs,
      isAr: isAr,
    );

    box(const SizedBox(height: 28));
    box(
      _SectionTitle(
        isAr ? 'تفصيل حسب المصدر' : 'Source breakdown',
        subtitle: isAr
            ? 'من مجموعة الصفقات (إيراد = السعر النهائي)'
            : 'From deals (revenue = final price)',
      ),
    );
    box(const SizedBox(height: 10));
    if (docs.isEmpty && !dealsLoading) {
      box(_EmptyHint(isAr: isAr));
    } else {
      out.add(
        SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: RepaintBoundary(
                child: _SourceBreakdownCardHeader(isAr: isAr),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (BuildContext c, int index) {
                  final r = bySource[index];
                  return _SourceBreakdownDataRow(
                    row: r,
                    isAr: isAr,
                    fmtKwd: fmtKwd,
                    isLast: index == bySource.length - 1,
                  );
                },
                childCount: bySource.length,
                addAutomaticKeepAlives: true,
                addRepaintBoundaries: true,
              ),
            ),
          ],
        ),
      );
    }

    box(const SizedBox(height: 28));
    box(
      _SectionTitle(
        isAr ? 'الصفقات عبر الزمن' : 'Deals over time',
        subtitle: isAr ? 'حسب تاريخ الإغلاق' : 'By closedAt',
      ),
    );
    box(const SizedBox(height: 10));
    box(
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
    );
    box(const SizedBox(height: 16));
    box(_DealsOverTimeChart(stats: byTime, isAr: isAr));

    box(const SizedBox(height: 28));
    box(
      _SectionTitle(
        isAr ? 'أبرز المناطق' : 'Top areas',
        subtitle: isAr
            ? 'محافظة + منطقة (أعلى 5 حسب الإيراد)'
            : 'Governorate + area (top 5 by revenue)',
      ),
    );
    box(const SizedBox(height: 10));
    if (byArea.isEmpty && docs.isNotEmpty) {
      box(
        Text(
          isAr ? 'لا توجد بيانات منطقة' : 'No area fields on sample',
          style: TextStyle(color: Colors.grey.shade600),
        ),
      );
    } else if (docs.isEmpty && !dealsLoading) {
      box(_EmptyHint(isAr: isAr));
    } else {
      for (final a in byArea) {
        final tile = a;
        box(_AreaTile(stats: tile, fmtKwd: fmtKwd, isAr: isAr));
      }
    }

    box(const SizedBox(height: 28));
    box(
      _SectionTitle(
        isAr ? 'أنواع العقار' : 'Property types',
        subtitle: isAr
            ? 'عدد الصفقات لكل نوع (العينة)'
            : 'Deal count per type (sample)',
      ),
    );
    box(const SizedBox(height: 10));
    if (docs.isEmpty && !dealsLoading) {
      box(_EmptyHint(isAr: isAr));
    } else {
      final maxCount = byType.isEmpty
          ? 1
          : byType.map((e) => e.count).reduce(math.max);
      for (final t in byType) {
        final row = t;
        box(
          _TypeBar(
            label: row.propertyType,
            count: row.count,
            maxCount: maxCount,
          ),
        );
      }
    }

    return out;
  }

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

  /// [CustomScrollView] with explicit dashboard slivers (no nested vertical lists).
  Widget _buildDashboardCustomScrollView(List<Widget> dashboardSlivers) {
    return CustomScrollView(
      key: const PageStorageKey<String>('adminDashboardBodyScroll'),
      cacheExtent: 800,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          sliver: SliverMainAxisGroup(
            slivers: dashboardSlivers,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    return StreamBuilder<GlobalAnalyticsSnapshot>(
        stream: _globalStream,
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
            stream: _dealsStream,
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
                stream: _viewsStream,
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

                  final showTopLoading =
                      globalLoading || dealsLoading || viewsLoading;

                  final dashboardSlivers = _buildDashboardSlivers(
                    context: context,
                    isAr: isAr,
                    showTopLoading: showTopLoading,
                    global: global,
                    docs: docs,
                    viewDocs: viewDocs,
                    bySource: bySource,
                    byTime: byTime,
                    byArea: byArea,
                    byType: byType,
                    dealsLoading: dealsLoading,
                  );

                  return _buildDashboardCustomScrollView(dashboardSlivers);
                },
              );
            },
          );
        },
    );
  }
}

class _AdminDashboardLoadingStrip extends StatelessWidget {
  const _AdminDashboardLoadingStrip({required this.show});

  final bool show;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: show ? 16 : 0),
      child: SizedBox(
        height: show ? 3 : 0,
        child: show
            ? const LinearProgressIndicator(minHeight: 3)
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _AdminDashboardExecutiveMetricsSection extends StatelessWidget {
  const _AdminDashboardExecutiveMetricsSection({
    required this.isAr,
    required this.global,
    required this.fmtKwd,
    required this.fmtPct,
    required this.aiPctFromGlobal,
  });

  final bool isAr;
  final GlobalAnalyticsSnapshot global;
  final String Function(num) fmtKwd;
  final String Function(double? share) fmtPct;
  final double? aiPctFromGlobal;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          isAr ? 'مؤشرات رئيسية' : 'Top metrics',
          subtitle: isAr
              ? 'من مستند التجميع السريع'
              : 'From analytics/global',
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final m1 = _MetricCard(
                label: isAr ? 'إجمالي الصفقات' : 'Total deals',
                value: '${global.totalDeals.round()}',
                icon: Icons.handshake_outlined,
              );
              final m2 = _MetricCard(
                label: isAr ? 'حجم التداول' : 'Total volume',
                value: fmtKwd(global.totalVolume),
                icon: Icons.payments_outlined,
              );
              final m3 = _MetricCard(
                label: isAr ? 'إجمالي العمولة' : 'Total commission',
                value: fmtKwd(global.totalCommission),
                icon: Icons.account_balance_wallet_outlined,
              );
              final m4 = _MetricCard(
                label: isAr
                    ? 'نسبة صفقات الذكاء الاصطناعي'
                    : 'AI deals share',
                value: fmtPct(aiPctFromGlobal),
                icon: Icons.smart_toy_outlined,
                foot: 'aiDeals ÷ totalDeals',
              );
              final innerW = constraints.maxWidth;
              final cellW = (innerW - 12) / 2;
              final aspect = cellW < 152 ? 0.92 : 1.1;
              return GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: aspect,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [m1, m2, m3, m4],
              );
            },
          ),
        ),
      ],
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

/// Top of source breakdown “card” (sits above [SliverList] data rows).
class _SourceBreakdownCardHeader extends StatelessWidget {
  const _SourceBreakdownCardHeader({required this.isAr});

  final bool isAr;

  static const double _hPad = 16;
  static const double _vPad = 12;

  @override
  Widget build(BuildContext context) {
    final headerStyle = const TextStyle(fontWeight: FontWeight.bold);
    final border = BorderSide(color: Colors.grey.shade200);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(14),
          topRight: Radius.circular(14),
        ),
        border: Border(top: border, left: border, right: border),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(13),
          topRight: Radius.circular(13),
        ),
        child: ColoredBox(
          color: AppColors.navy.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _hPad,
              vertical: _vPad,
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    isAr ? 'المصدر' : 'Source',
                    style: headerStyle,
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: Text(
                    isAr ? 'الصفقات' : 'Deals',
                    style: headerStyle,
                    textAlign: TextAlign.end,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    isAr ? 'الإيراد' : 'Revenue',
                    style: headerStyle,
                    textAlign: TextAlign.end,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    isAr ? 'العمولة' : 'Commission',
                    style: headerStyle,
                    textAlign: TextAlign.end,
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

class _SourceBreakdownDataRow extends StatelessWidget {
  const _SourceBreakdownDataRow({
    required this.row,
    required this.isAr,
    required this.fmtKwd,
    required this.isLast,
  });

  final SourceStats row;
  final bool isAr;
  final String Function(num) fmtKwd;
  final bool isLast;

  static const double _hPad = 16;
  static const double _vPad = 12;

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: Colors.grey.shade200);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          left: side,
          right: side,
          bottom: side,
        ),
        borderRadius: isLast
            ? const BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              )
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: _vPad),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                isAr ? row.displayLabelAr : row.displayLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 1,
              child: Text(
                '${row.dealCount}',
                textAlign: TextAlign.end,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                fmtKwd(row.totalRevenue),
                textAlign: TextAlign.end,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                fmtKwd(row.totalCommission),
                textAlign: TextAlign.end,
              ),
            ),
          ],
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
        child: RepaintBoundary(
          child: SizedBox(
            height: 220,
            child: IgnorePointer(
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
                      isCurved: false,
                      color: AppColors.navy,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: AppColors.navy.withValues(alpha: 0.08),
                      ),
                    ),
                  ],
                  lineTouchData: const LineTouchData(enabled: false),
                ),
                duration: Duration.zero,
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

/// Strings/helpers for the intelligence block (slivers built in [_DashboardStreamsState]).
abstract final class _IntelligenceUi {
  static String fmtConv(double r) => '${(r * 100).toStringAsFixed(2)}%';

  static bool isPositiveInsight(String en) {
    return en.contains('strongly') || en.contains('High conversion');
  }

  static String sourceLabel(String key, bool isAr) {
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
        case DealLeadSource.interestedButton:
          return 'زر أنا مهتم';
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
      case DealLeadSource.interestedButton:
        return 'I\'m interested';
      default:
        return 'Unknown';
    }
  }

  static String? intelAr(String en) {
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
}

class _IntelligenceConversionTableHeader extends StatelessWidget {
  const _IntelligenceConversionTableHeader({required this.isAr});

  final bool isAr;

  static const double _hPad = 16;
  static const double _vPad = 12;

  @override
  Widget build(BuildContext context) {
    final headerStyle = const TextStyle(fontWeight: FontWeight.bold);
    final border = BorderSide(color: Colors.grey.shade200);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(14),
          topRight: Radius.circular(14),
        ),
        border: Border(top: border, left: border, right: border),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(13),
          topRight: Radius.circular(13),
        ),
        child: ColoredBox(
          color: AppColors.navy.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _hPad,
              vertical: _vPad,
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    isAr ? 'المصدر' : 'Source',
                    style: headerStyle,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    isAr ? 'مشاهدات' : 'Views',
                    style: headerStyle,
                    textAlign: TextAlign.end,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    isAr ? 'صفقات' : 'Deals',
                    style: headerStyle,
                    textAlign: TextAlign.end,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    isAr ? 'تحويل' : 'Conv.',
                    style: headerStyle,
                    textAlign: TextAlign.end,
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

class _IntelligenceConversionDataRow extends StatelessWidget {
  const _IntelligenceConversionDataRow({
    required this.sourceLabel,
    required this.views,
    required this.deals,
    required this.convLabel,
    required this.isLast,
  });

  final String sourceLabel;
  final String views;
  final String deals;
  final String convLabel;
  final bool isLast;

  static const double _hPad = 16;
  static const double _vPad = 12;

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: Colors.grey.shade200);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(left: side, right: side, bottom: side),
        borderRadius: isLast
            ? const BorderRadius.only(
                bottomLeft: Radius.circular(14),
                bottomRight: Radius.circular(14),
              )
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: _vPad),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                sourceLabel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(views, textAlign: TextAlign.end),
            ),
            Expanded(
              flex: 2,
              child: Text(deals, textAlign: TextAlign.end),
            ),
            Expanded(
              flex: 2,
              child: Text(convLabel, textAlign: TextAlign.end),
            ),
          ],
        ),
      ),
    );
  }
}
