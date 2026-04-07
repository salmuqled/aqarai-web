import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

/// Sale vs rental mix for **pipeline leads only** (`new` / `contacted` / `qualified`)
/// from the same [dealDocs] as the dashboard (no extra queries).
class AdminLeadsSplitSection extends StatelessWidget {
  const AdminLeadsSplitSection({
    super.key,
    required this.dealDocs,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;

  /// Pre-deal stages only (excludes booked / signed / closed / not_interested / invalid).
  static bool _isLeadStage(String statusRaw) {
    if (!isValidDealStatus(statusRaw)) return false;
    if (statusRaw == DealStatus.notInterested) return false;
    return statusRaw == DealStatus.newLead ||
        statusRaw == DealStatus.contacted ||
        statusRaw == DealStatus.qualified;
  }

  static ({
    int sales,
    int rental,
    int salesActive,
    int rentalActive,
    int otherService,
  }) aggregate(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    var sales = 0;
    var rental = 0;
    var otherService = 0;

    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      if (isFinalizedDeal(m)) continue;

      final st = m['dealStatus']?.toString().trim() ?? '';
      if (!_isLeadStage(st)) continue;

      final bucket = getServiceBucket(m);
      if (bucket == null) {
        otherService++;
        continue;
      }

      if (bucket == 'rent') {
        rental++;
      } else {
        sales++;
      }
    }

    return (
      sales: sales,
      rental: rental,
      salesActive: sales,
      rentalActive: rental,
      otherService: otherService,
    );
  }

  static String? _sharePct(int part, int total) {
    if (total <= 0) return null;
    return '${((part / total) * 100).clamp(0, 100).toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final agg = aggregate(dealDocs);
    final total = agg.sales + agg.rental;
    final salesPct = _sharePct(agg.sales, total);
    final rentalPct = _sharePct(agg.rental, total);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          loc.adminLeadsSplitSectionTitle,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          loc.adminLeadsSplitSectionSubtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 480;
            final gap = 12.0;
            final salesCard = _LeadSplitCard(
              label: loc.adminLeadsSplitSalesLabel,
              count: agg.sales,
              share: salesPct,
              activeCount: agg.salesActive,
              accent: Colors.blue.shade700,
              light: Colors.blue.shade50,
              loc: loc,
              isAr: isAr,
            );
            final rentalCard = _LeadSplitCard(
              label: loc.adminLeadsSplitRentalLabel,
              count: agg.rental,
              share: rentalPct,
              activeCount: agg.rentalActive,
              accent: Colors.green.shade700,
              light: Colors.green.shade50,
              loc: loc,
              isAr: isAr,
            );
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: salesCard),
                  SizedBox(width: gap),
                  Expanded(child: rentalCard),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                salesCard,
                SizedBox(height: gap),
                rentalCard,
              ],
            );
          },
        ),
        if (agg.otherService > 0) ...[
          const SizedBox(height: 8),
          Text(
            loc.adminLeadsSplitOtherServiceTypes(agg.otherService),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            textAlign: isAr ? TextAlign.right : TextAlign.start,
          ),
        ],
      ],
    );
  }
}

class _LeadSplitCard extends StatelessWidget {
  const _LeadSplitCard({
    required this.label,
    required this.count,
    required this.share,
    required this.activeCount,
    required this.accent,
    required this.light,
    required this.loc,
    required this.isAr,
  });

  final String label;
  final int count;
  final String? share;
  final int activeCount;
  final Color accent;
  final Color light;
  final AppLocalizations loc;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final shareText = share == null ? '' : ' ($share)';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: accent.withValues(alpha: 0.35)),
      ),
      color: light,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline, size: 20, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: accent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '$count$shareText',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: accent,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              loc.adminLeadsSplitActivePipeline(activeCount),
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade800.withValues(alpha: 0.85),
                height: 1.3,
              ),
              textAlign: isAr ? TextAlign.right : TextAlign.start,
            ),
          ],
        ),
      ),
    );
  }
}
