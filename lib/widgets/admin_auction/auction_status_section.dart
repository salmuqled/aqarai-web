import 'package:flutter/material.dart';

import 'package:aqarai_app/models/auction/auction.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/services/auction/auction_log_service.dart';
import 'package:aqarai_app/services/auction/auction_service.dart';

/// Auction-level status + Start live / End (finished) controls.
class AuctionStatusSection extends StatelessWidget {
  const AuctionStatusSection({
    super.key,
    required this.auction,
    required this.adminUid,
    required this.isArabic,
    required this.onAction,
  });

  final Auction auction;
  final String adminUid;
  final bool isArabic;
  final Future<void> Function(Future<void> Function() run) onAction;

  Future<void> _setStatus(BuildContext context, AuctionStatus next) async {
    final msg = isArabic
        ? 'تأكيد تغيير حالة المزاد؟'
        : 'Change auction status?';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(msg),
        content: Text(next.firestoreValue),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isArabic ? 'تأكيد' : 'Confirm'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    await onAction(() async {
      await AuctionService.updateAuctionStatus(
        auctionId: auction.id,
        status: next,
      );
      await AuctionLogService.append(
        auctionId: auction.id,
        action: AuctionLogActions.auctionStatusChanged,
        performedBy: adminUid,
        details: {'status': next.firestoreValue},
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = auction.status;
    final isLive = s == AuctionStatus.live;
    final isFinished = s == AuctionStatus.finished;

    Color statusColor;
    switch (s) {
      case AuctionStatus.live:
        statusColor = Colors.red.shade700;
      case AuctionStatus.finished:
      case AuctionStatus.closed:
        statusColor = Colors.grey.shade600;
      default:
        statusColor = Colors.blueGrey;
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'حالة المزاد' : 'Auction status',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    s.firestoreValue,
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: (isLive || isFinished)
                      ? null
                      : () => _setStatus(context, AuctionStatus.live),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(isArabic ? 'بدء المزاد (مباشر)' : 'Start auction (live)'),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: !isLive
                      ? null
                      : () => _setStatus(context, AuctionStatus.finished),
                  icon: const Icon(Icons.stop),
                  label: Text(isArabic ? 'إنهاء المزاد' : 'End auction'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
