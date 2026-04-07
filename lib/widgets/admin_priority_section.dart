import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

enum _PriorityTier { high, medium, low }

/// Ranks unpaid commission deals (booked / signed / closed) for follow-up — in-memory [dealDocs] only.
class AdminPrioritySection extends StatelessWidget {
  const AdminPrioritySection({
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

  /// Spec: status points + commission band points.
  static int _scoreFor(String status, double commission) {
    var s = 0;
    if (status == DealStatus.signed) {
      s += 50;
    } else if (status == DealStatus.booked) {
      s += 30;
    } else if (status == DealStatus.closed) {
      s += 40;
    }
    if (commission > 1000) {
      s += 50;
    } else if (commission > 500) {
      s += 30;
    } else {
      s += 10;
    }
    return s;
  }

  static _PriorityTier _tierForScore(int score) {
    if (score >= 80) return _PriorityTier.high;
    if (score >= 50) return _PriorityTier.medium;
    return _PriorityTier.low;
  }

  static List<
      ({
        String title,
        double commission,
        String status,
        int score,
        _PriorityTier tier,
      })> computeTop(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
    int limit = 5,
  }) {
    final rows = <({
      String title,
      double commission,
      String status,
      int score,
      _PriorityTier tier,
    })>[];

    for (final d in docs) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final statusRaw = m['dealStatus']?.toString().trim() ?? '';
      if (!isValidDealStatus(statusRaw)) continue;
      if (statusRaw != DealStatus.booked &&
          statusRaw != DealStatus.signed &&
          statusRaw != DealStatus.closed) {
        continue;
      }
      if (isPaid(m)) continue;
      final comm = getCommission(m);
      if (comm <= 0) continue;

      final score = _scoreFor(statusRaw, comm);
      final tier = _tierForScore(score);
      rows.add((
        title: _propertyTitle(m),
        commission: comm,
        status: statusRaw,
        score: score,
        tier: tier,
      ));
    }

    rows.sort((a, b) => b.score.compareTo(a.score));
    if (rows.length <= limit) return rows;
    return rows.sublist(0, limit);
  }

  static String _statusLabel(AppLocalizations loc, String status) {
    switch (status) {
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

  static String _priorityLabel(AppLocalizations loc, _PriorityTier tier) {
    switch (tier) {
      case _PriorityTier.high:
        return loc.adminPriorityLabelHigh;
      case _PriorityTier.medium:
        return loc.adminPriorityLabelMedium;
      case _PriorityTier.low:
        return loc.adminPriorityLabelLow;
    }
  }

  static ({Color accent, Color bg}) _colorsFor(_PriorityTier tier) {
    switch (tier) {
      case _PriorityTier.high:
        return (accent: Colors.red.shade700, bg: Colors.red.shade50);
      case _PriorityTier.medium:
        return (accent: Colors.orange.shade800, bg: Colors.orange.shade50);
      case _PriorityTier.low:
        return (accent: Colors.grey.shade700, bg: Colors.grey.shade100);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final items = computeTop(dealDocs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          loc.adminPrioritySectionTitle,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          loc.adminPrioritySectionSubtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            color: Colors.grey.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                loc.adminPriorityEmpty,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                textAlign: isAr ? TextAlign.right : TextAlign.start,
              ),
            ),
          )
        else
          ...items.map(
            (e) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PriorityDealCard(
                title: e.title,
                commissionStr: fmtKwd(e.commission),
                statusStr: _statusLabel(loc, e.status),
                priorityStr: _priorityLabel(loc, e.tier),
                tier: e.tier,
                isAr: isAr,
              ),
            ),
          ),
      ],
    );
  }
}

class _PriorityDealCard extends StatelessWidget {
  const _PriorityDealCard({
    required this.title,
    required this.commissionStr,
    required this.statusStr,
    required this.priorityStr,
    required this.tier,
    required this.isAr,
  });

  final String title;
  final String commissionStr;
  final String statusStr;
  final String priorityStr;
  final _PriorityTier tier;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final c = AdminPrioritySection._colorsFor(tier);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.accent.withValues(alpha: 0.45)),
      ),
      color: c.bg,
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: c.accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade900,
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: isAr ? TextAlign.right : TextAlign.start,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: c.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            priorityStr,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: c.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      commissionStr,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: c.accent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      statusStr,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
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
