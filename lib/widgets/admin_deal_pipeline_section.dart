import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

/// Pipeline counts from the same `deals` sample as [AdminAnalyticsService.watchDealsForDashboard]
/// (no extra Firestore listener). Financial totals use `lib/utils/financial_rules.dart`.
class AdminDealPipelineSection extends StatelessWidget {
  const AdminDealPipelineSection({
    super.key,
    required this.dealDocs,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;

  static const List<String> _orderedStages = [
    DealStatus.newLead,
    DealStatus.contacted,
    DealStatus.qualified,
    DealStatus.booked,
    DealStatus.signed,
    DealStatus.notInterested,
    DealStatus.closed,
  ];

  /// Returns per-stage counts plus deals whose [dealStatus] is null, empty, or not a valid stage.
  static ({Map<String, int> stages, int other}) countStages(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final stages = {
      for (final k in _orderedStages) k: 0,
    };
    var other = 0;
    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final raw = m['dealStatus']?.toString().trim() ?? '';
      if (raw.isEmpty || !isValidDealStatus(raw)) {
        other++;
        if (kDebugMode) {
          final label = raw.isEmpty ? '<missing>' : raw;
          debugPrint('Invalid dealStatus detected: $label');
        }
        continue;
      }
      stages[raw] = (stages[raw] ?? 0) + 1;
    }
    return (stages: stages, other: other);
  }

  Color _accentFor(String status) {
    switch (status) {
      case DealStatus.newLead:
        return Colors.grey.shade600;
      case DealStatus.contacted:
        return Colors.blue.shade700;
      case DealStatus.qualified:
        return Colors.purple.shade700;
      case DealStatus.booked:
        return Colors.orange.shade700;
      case DealStatus.signed:
        return Colors.green.shade600;
      case DealStatus.closed:
        return Colors.green.shade900;
      case DealStatus.notInterested:
        return Colors.red.shade800;
      default:
        return Colors.grey;
    }
  }

  String _label(AppLocalizations loc, String status) {
    switch (status) {
      case DealStatus.newLead:
        return loc.adminDealPipelineNewLeads;
      case DealStatus.contacted:
        return loc.adminDealPipelineContacted;
      case DealStatus.qualified:
        return loc.adminDealPipelineQualified;
      case DealStatus.booked:
        return loc.adminDealPipelineBooked;
      case DealStatus.signed:
        return loc.adminDealPipelineSigned;
      case DealStatus.closed:
        return loc.adminDealPipelineClosed;
      case DealStatus.notInterested:
        return loc.adminDealPipelineNotInterested;
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final agg = countStages(dealDocs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          loc.adminDealPipelineSectionTitle,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          loc.adminDealPipelineSectionSubtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 520;
            final cols = wide ? 3 : 2;
            final spacing = 10.0;
            final cardW = (c.maxWidth - spacing * (cols - 1)) / cols;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final status in _orderedStages)
                  SizedBox(
                    width: cardW,
                    child: _StageCard(
                      label: _label(loc, status),
                      count: agg.stages[status] ?? 0,
                      accent: _accentFor(status),
                    ),
                  ),
              ],
            );
          },
        ),
        if (agg.other > 0) ...[
          const SizedBox(height: 8),
          Text(
            loc.adminDealPipelineOtherCount(agg.other),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          loc.adminDealPipelineSectionFootnote,
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

class _StageCard extends StatelessWidget {
  const _StageCard({
    required this.label,
    required this.count,
    required this.accent,
  });

  final String label;
  final int count;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
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
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 20,
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
