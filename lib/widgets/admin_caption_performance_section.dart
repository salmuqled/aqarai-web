import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/caption_performance.dart';
import 'package:aqarai_app/services/caption_performance_service.dart';

/// Admin dashboard: caption A/B/C clicks + CTR (from Firestore samples).
class AdminCaptionPerformanceSection extends StatelessWidget {
  const AdminCaptionPerformanceSection({
    super.key,
    required this.isAr,
  });

  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final svc = CaptionPerformanceService();

    return FutureBuilder<List<CaptionPerformance>>(
      future: svc.getPerformance(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              isAr
                  ? 'تعذّر تحميل أداء الكابشن.'
                  : 'Could not load caption performance.',
              style: TextStyle(color: Colors.red.shade800, fontSize: 13),
            ),
          );
        }
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final rows = snap.data!;
        final maxClicks =
            rows.isEmpty ? 0 : rows.map((e) => e.clicks).reduce(math.max);
        final bestIds = maxClicks > 0
            ? rows
                .where((e) => e.clicks == maxClicks)
                .map((e) => e.captionId)
                .toSet()
            : <String>{};

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.adminCaptionPerformanceTitle,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              loc.adminCaptionPerformanceSubtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            ...rows.map((r) {
              final best = bestIds.contains(r.captionId);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: best ? Colors.amber.shade50 : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: best
                          ? Colors.amber.shade700
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _emojiFor(r.captionId),
                        style: const TextStyle(fontSize: 18),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          loc.adminCaptionPerformanceRow(
                            r.captionId,
                            r.clicks,
                            (r.ctr * 100).toStringAsFixed(1),
                          ),
                          style: TextStyle(
                            fontWeight: best ? FontWeight.w700 : FontWeight.w500,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (best)
                        Text(
                          '⭐',
                          style: TextStyle(fontSize: 16),
                        ),
                    ],
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }

  static String _emojiFor(String id) {
    switch (id) {
      case 'A':
        return '🔥';
      case 'B':
        return '📈';
      case 'C':
        return '📉';
      default:
        return '📊';
    }
  }
}
