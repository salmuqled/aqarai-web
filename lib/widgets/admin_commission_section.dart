import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

/// Sums commission from the same `deals` sample as the dashboard (no extra queries).
/// Uses `isFinalizedDeal`, `getCommission`, `getServiceBucket`, and `isPaid` from
/// `financial_rules.dart`. Only finalized deals with positive commission are included.
class AdminCommissionSection extends StatelessWidget {
  const AdminCommissionSection({
    super.key,
    required this.dealDocs,
    required this.fmtKwd,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;
  final String Function(num n) fmtKwd;

  static ({
    double total,
    double paid,
    double pending,
    int dealCount,
    double salesCommission,
    double rentalCommission,
    double otherCommission,
  }) aggregate(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    var total = 0.0;
    var paid = 0.0;
    var pending = 0.0;
    var salesCommission = 0.0;
    var rentalCommission = 0.0;
    var otherCommission = 0.0;
    var n = 0;
    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final statusRaw = m['dealStatus']?.toString().trim() ?? '';
      if (!isValidDealStatus(statusRaw)) continue;
      if (!isFinalizedDeal(m)) continue;
      final comm = getCommission(m);
      if (comm <= 0) continue;
      n++;
      total += comm;
      final bucket = getServiceBucket(m);
      if (bucket == 'rent') {
        rentalCommission += comm;
      } else if (bucket == 'sale') {
        salesCommission += comm;
      } else {
        otherCommission += comm;
      }
      if (isPaid(m)) {
        paid += comm;
      } else {
        pending += comm;
      }
    }
    return (
      total: total,
      paid: paid,
      pending: pending,
      dealCount: n,
      salesCommission: salesCommission,
      rentalCommission: rentalCommission,
      otherCommission: otherCommission,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final agg = aggregate(dealDocs);

    final rate = agg.total > 0 ? (agg.paid / agg.total) : null;
    final rateStr = rate == null
        ? '—'
        : '${(rate * 100).clamp(0, 100).toStringAsFixed(0)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          loc.adminCommissionSectionTitle,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          loc.adminCommissionSectionSubtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 520;
            const spacing = 10.0;

            Widget rowOrCol(List<Widget> children) {
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) SizedBox(width: spacing),
                      Expanded(child: children[i]),
                    ],
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) SizedBox(height: spacing),
                    children[i],
                  ],
                ],
              );
            }

            return rowOrCol([
              _CommissionCard(
                label: loc.adminCommissionTotal,
                value: fmtKwd(agg.total),
                accent: AppColors.navy,
                icon: Icons.payments_outlined,
              ),
              _CommissionCard(
                label: loc.adminCommissionPaid,
                value: fmtKwd(agg.paid),
                accent: Colors.green.shade700,
                icon: Icons.check_circle_outline,
              ),
              _CommissionCard(
                label: loc.adminCommissionPending,
                value: fmtKwd(agg.pending),
                accent: Colors.orange.shade800,
                icon: Icons.schedule,
              ),
            ]);
          },
        ),
        if (agg.dealCount > 0) ...[
          const SizedBox(height: 12),
          _CommissionServiceBreakdown(
            loc: loc,
            fmtKwd: fmtKwd,
            sales: agg.salesCommission,
            rental: agg.rentalCommission,
            other: agg.otherCommission,
            totalForShare: agg.total,
            isAr: isAr,
          ),
        ],
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.percent, size: 22, color: Colors.teal.shade700),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    loc.adminCommissionCollectionRate(rateStr),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (agg.dealCount == 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              loc.adminCommissionNoDealsInSample,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              textAlign: isAr ? TextAlign.right : TextAlign.start,
            ),
          ),
      ],
    );
  }
}

class _CommissionServiceBreakdown extends StatelessWidget {
  const _CommissionServiceBreakdown({
    required this.loc,
    required this.fmtKwd,
    required this.sales,
    required this.rental,
    required this.other,
    required this.totalForShare,
    required this.isAr,
  });

  final AppLocalizations loc;
  final String Function(num n) fmtKwd;
  final double sales;
  final double rental;
  final double other;
  final double totalForShare;
  final bool isAr;

  static String? _pct(double part, double total) {
    if (total <= 0) return null;
    return '${((part / total) * 100).clamp(0, 100).toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final salesBlue = Colors.blue.shade700;
    final rentalGreen = Colors.green.shade700;
    final otherGrey = Colors.grey.shade700;
    final salesPct = _pct(sales, totalForShare);
    final rentalPct = _pct(rental, totalForShare);
    final otherPct = _pct(other, totalForShare);

    Widget richLine(String label, double amount, Color accent, String? pct) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              TextSpan(
                text: fmtKwd(amount),
                style: const TextStyle(
                  color: AppColors.navy,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              if (pct != null)
                TextSpan(
                  text: ' ($pct)',
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
            ],
          ),
          textAlign: isAr ? TextAlign.right : TextAlign.start,
          textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        ),
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            richLine(loc.adminCommissionSplitSalesLabel, sales, salesBlue, salesPct),
            richLine(loc.adminCommissionSplitRentalLabel, rental, rentalGreen, rentalPct),
            richLine(loc.adminCommissionSplitOtherLabel, other, otherGrey, otherPct),
          ],
        ),
      ),
    );
  }
}

class _CommissionCard extends StatelessWidget {
  const _CommissionCard({
    required this.label,
    required this.value,
    required this.accent,
    required this.icon,
  });

  final String label;
  final String value;
  final Color accent;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, color: accent, size: 22),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: AppColors.navy,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
