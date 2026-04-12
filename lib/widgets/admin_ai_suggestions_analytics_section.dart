import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/services/ai_suggestions_analytics_service.dart';

enum _AiWindow { h24, d7, d30 }

class AdminAiSuggestionsAnalyticsSection extends StatefulWidget {
  const AdminAiSuggestionsAnalyticsSection({super.key});

  @override
  State<AdminAiSuggestionsAnalyticsSection> createState() =>
      _AdminAiSuggestionsAnalyticsSectionState();
}

class _AdminAiSuggestionsAnalyticsSectionState
    extends State<AdminAiSuggestionsAnalyticsSection> {
  final AiSuggestionsAnalyticsService _svc = AiSuggestionsAnalyticsService();

  _AiWindow _window = _AiWindow.d7;

  Duration _dur(_AiWindow w) {
    switch (w) {
      case _AiWindow.h24:
        return const Duration(hours: 24);
      case _AiWindow.d7:
        return const Duration(days: 7);
      case _AiWindow.d30:
        return const Duration(days: 30);
    }
  }

  String _label(BuildContext context, _AiWindow w) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    switch (w) {
      case _AiWindow.h24:
        return isAr ? 'آخر ٢٤ ساعة' : 'Last 24h';
      case _AiWindow.d7:
        return isAr ? 'آخر ٧ أيام' : 'Last 7 days';
      case _AiWindow.d30:
        return isAr ? 'آخر ٣٠ يوم' : 'Last 30 days';
    }
  }

  static String _pct(double? r) {
    if (r == null) return '—';
    return '${(r * 100).clamp(0, 999).toStringAsFixed(1)}%';
  }

  static String _kwd(double n) {
    final v = (n * 1000).roundToDouble() / 1000;
    if (v == v.roundToDouble()) return '${v.toStringAsFixed(0)} KWD';
    return '${v.toStringAsFixed(2)} KWD';
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    Widget metricCard({
      required String label,
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
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.navy),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              if (foot != null) ...[
                const SizedBox(height: 6),
                Text(
                  foot,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final future = _svc.load(window: _dur(_window));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                isAr ? 'تحليلات اقتراحات الذكاء الاصطناعي' : 'AI Suggestions analytics',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.navy,
                ),
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<_AiWindow>(
              value: _window,
              onChanged: (v) {
                if (v == null) return;
                setState(() => _window = v);
              },
              items: _AiWindow.values
                  .map((w) => DropdownMenuItem<_AiWindow>(
                        value: w,
                        child: Text(_label(context, w)),
                      ))
                  .toList(),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          isAr
              ? 'المصدر: feature_suggestion_events (shown/clicked/conversion).'
              : 'Source: feature_suggestion_events (shown/clicked/conversion).',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        FutureBuilder<AiSuggestionAnalyticsSnapshot>(
          future: future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: CircularProgressIndicator(),
              ));
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
                    isAr ? 'تعذر تحميل تحليلات AI: ${snap.error}' : 'Failed to load AI analytics: ${snap.error}',
                    style: TextStyle(color: Colors.red.shade800),
                  ),
                ),
              );
            }

            final d = snap.data!;
            final top = d.topSuggestionType;
            final topLabel = top == null
                ? (isAr ? '—' : '—')
                : '$top (${_kwd(d.topSuggestionTypeRevenueKwd)})';

            final cards = <Widget>[
              metricCard(
                label: isAr ? 'إجمالي الظهور' : 'Total shown',
                value: '${d.totalShown}',
                icon: Icons.visibility_outlined,
              ),
              metricCard(
                label: isAr ? 'إجمالي النقرات' : 'Total clicked',
                value: '${d.totalClicked}',
                icon: Icons.ads_click_outlined,
              ),
              metricCard(
                label: isAr ? 'إجمالي التحويلات' : 'Total conversions',
                value: '${d.totalConversions}',
                icon: Icons.verified_outlined,
              ),
              metricCard(
                label: isAr ? 'CTR' : 'CTR',
                value: _pct(d.ctr),
                icon: Icons.percent_outlined,
                foot: 'clicked ÷ shown',
              ),
              metricCard(
                label: isAr ? 'نسبة التحويل' : 'Conversion rate',
                value: _pct(d.conversionRate),
                icon: Icons.trending_up_outlined,
                foot: 'conversions ÷ clicked',
              ),
              metricCard(
                label: isAr ? 'إيراد AI' : 'AI revenue',
                value: _kwd(d.totalRevenueKwd),
                icon: Icons.payments_outlined,
              ),
              metricCard(
                label: isAr ? 'إيراد لكل ظهور' : 'Revenue per shown',
                value: _kwd(d.revenuePerShown),
                icon: Icons.savings_outlined,
                foot: 'revenue ÷ shown',
              ),
              metricCard(
                label: isAr ? 'أفضل نوع اقتراح' : 'Top suggestion type',
                value: topLabel,
                icon: Icons.emoji_events_outlined,
              ),
            ];

            return LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 720;
                final crossAxisCount = wide ? 4 : 2;
                return GridView.count(
                  crossAxisCount: crossAxisCount,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: wide ? 2.6 : 2.2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  children: cards,
                );
              },
            );
          },
        ),
      ],
    );
  }
}

