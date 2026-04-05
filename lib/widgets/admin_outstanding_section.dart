import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

/// Finalized deals (signed/closed) with positive commission not yet marked paid — same [dealDocs] as dashboard.
class AdminOutstandingSection extends StatelessWidget {
  const AdminOutstandingSection({
    super.key,
    required this.dealDocs,
    required this.fmtKwd,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;
  final String Function(num n) fmtKwd;

  static String _propertyTitle(Map<String, dynamic> m) {
    final t = (m['propertyTitle'] ?? m['title'] ?? '').toString().trim();
    return t.isEmpty ? '—' : t;
  }

  static ({int count, double amount, List<({String title, double commission})> top}) aggregate(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final rows = <({Map<String, dynamic> m, double commission})>[];
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
      if (isPaid(m)) continue;
      final comm = getCommission(m);
      if (comm <= 0) continue;
      rows.add((m: m, commission: comm));
    }

    final amount = rows.fold<double>(0, (s, e) => s + e.commission);
    rows.sort((a, b) => b.commission.compareTo(a.commission));
    final top = rows
        .take(3)
        .map((e) => (title: _propertyTitle(e.m), commission: e.commission))
        .toList();

    return (count: rows.length, amount: amount, top: top);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final agg = aggregate(dealDocs);

    if (agg.count == 0) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.shade300),
        ),
        color: Colors.grey.shade50,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.check_circle_outline, color: Colors.green.shade700, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      loc.adminOutstandingSectionTitle,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                loc.adminOutstandingEmpty,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700, height: 1.35),
                textAlign: isAr ? TextAlign.right : TextAlign.start,
              ),
            ],
          ),
        ),
      );
    }

    final warnBg = Colors.orange.shade50;
    final warnBorder = Colors.orange.shade400;
    final warnFg = Colors.orange.shade900;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: warnBorder, width: 1.5),
      ),
      color: warnBg,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: warnFg, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    loc.adminOutstandingSectionTitle,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: warnFg,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              loc.adminOutstandingAmountLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: warnFg.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              fmtKwd(agg.amount),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: warnFg,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              loc.adminOutstandingDealsCount(agg.count),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: warnFg,
              ),
            ),
            if (agg.top.isNotEmpty) ...[
              const SizedBox(height: 16),
              Divider(color: warnBorder.withValues(alpha: 0.5)),
              const SizedBox(height: 8),
              Text(
                loc.adminOutstandingTopTitle,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: warnFg,
                ),
              ),
              const SizedBox(height: 8),
              for (final row in agg.top)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          row.title,
                          style: TextStyle(
                            fontSize: 13,
                            color: warnFg.withValues(alpha: 0.95),
                            height: 1.25,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        fmtKwd(row.commission),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: warnFg,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
