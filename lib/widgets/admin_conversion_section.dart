import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

/// Conversion-style ratios between pipeline stages from the same `deals` sample as the dashboard.
/// Only documents with a valid [dealStatus] contribute to counts; missing/invalid are skipped.
/// Commission and payment semantics for money widgets live in `lib/utils/financial_rules.dart`.
class AdminConversionSection extends StatelessWidget {
  const AdminConversionSection({
    super.key,
    required this.dealDocs,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;

  static const List<String> _funnelStages = [
    DealStatus.newLead,
    DealStatus.contacted,
    DealStatus.qualified,
    DealStatus.booked,
    DealStatus.signed,
  ];

  /// Counts only deals whose [dealStatus] is valid; excludes missing/invalid entirely.
  static Map<String, int> countValidStagesOnly(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final counts = {for (final s in _funnelStages) s: 0};
    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final raw = m['dealStatus']?.toString().trim() ?? '';
      if (!isValidDealStatus(raw)) continue;
      if (counts.containsKey(raw)) {
        counts[raw] = (counts[raw] ?? 0) + 1;
      }
      // Valid statuses outside the five (e.g. closed) are ignored for this funnel.
    }
    return counts;
  }

  static double? _rate(int numerator, int denominator) {
    if (denominator <= 0) return null;
    return numerator / denominator;
  }

  static String _fmtPct(double? r) {
    if (r == null) return '—';
    return '${(r * 100).clamp(0, 999).toStringAsFixed(0)}%';
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final c = countValidStagesOnly(dealDocs);

    final newCount = c[DealStatus.newLead] ?? 0;
    final contactedCount = c[DealStatus.contacted] ?? 0;
    final qualifiedCount = c[DealStatus.qualified] ?? 0;
    final bookedCount = c[DealStatus.booked] ?? 0;
    final signedCount = c[DealStatus.signed] ?? 0;

    final r1 = _rate(contactedCount, newCount);
    final r2 = _rate(qualifiedCount, contactedCount);
    final r3 = _rate(bookedCount, qualifiedCount);
    final r4 = _rate(signedCount, bookedCount);

    final rows = <_FunnelRowData>[
      _FunnelRowData(
        label: loc.adminConversionFunnelNewToContacted,
        fromCount: newCount,
        toCount: contactedCount,
        rate: r1,
      ),
      _FunnelRowData(
        label: loc.adminConversionFunnelContactedToQualified,
        fromCount: contactedCount,
        toCount: qualifiedCount,
        rate: r2,
      ),
      _FunnelRowData(
        label: loc.adminConversionFunnelQualifiedToBooked,
        fromCount: qualifiedCount,
        toCount: bookedCount,
        rate: r3,
      ),
      _FunnelRowData(
        label: loc.adminConversionFunnelBookedToSigned,
        fromCount: bookedCount,
        toCount: signedCount,
        rate: r4,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          loc.adminConversionSectionTitle,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          loc.adminConversionSectionSubtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        ...rows.map((row) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _FunnelRow(data: row),
            )),
        const SizedBox(height: 4),
        Text(
          loc.adminConversionSectionFootnote,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade600,
            height: 1.35,
          ),
          textAlign: isAr ? TextAlign.right : TextAlign.start,
        ),
      ],
    );
  }
}

class _FunnelRowData {
  const _FunnelRowData({
    required this.label,
    required this.fromCount,
    required this.toCount,
    required this.rate,
  });

  final String label;
  final int fromCount;
  final int toCount;
  final double? rate;
}

class _FunnelRow extends StatelessWidget {
  const _FunnelRow({required this.data});

  final _FunnelRowData data;

  @override
  Widget build(BuildContext context) {
    final pct = AdminConversionSection._fmtPct(data.rate);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              data.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${data.fromCount} → ${data.toCount}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '($pct)',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.teal.shade700,
                  ),
                ),
              ],
            ),
            if (data.rate != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: data.rate!.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: Colors.grey.shade200,
                  color: AppColors.navy.withValues(alpha: 0.85),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
