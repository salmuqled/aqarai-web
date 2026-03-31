import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/models/auction/auction.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/services/auction/auction_log_service.dart';
import 'package:aqarai_app/services/auction/auction_time_service.dart';
import 'package:aqarai_app/services/auction/lot_service.dart';
import 'package:aqarai_app/services/auction/permission_service.dart';

/// Current active lot summary + safety controls (pause / resume / emergency).
class ActiveLotControlSection extends StatefulWidget {
  const ActiveLotControlSection({
    super.key,
    required this.auction,
    required this.activeLot,
    required this.adminUid,
    required this.isArabic,
    required this.onAction,
  });

  final Auction auction;
  final AuctionLot? activeLot;
  final String adminUid;
  final bool isArabic;
  final Future<void> Function(Future<void> Function() run) onAction;

  @override
  State<ActiveLotControlSection> createState() =>
      _ActiveLotControlSectionState();
}

class _ActiveLotControlSectionState extends State<ActiveLotControlSection> {
  Timer? _ticker;
  DateTime _now = AuctionTimeService.instance.now();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = AuctionTimeService.instance.now());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _pause() async {
    final lot = widget.activeLot;
    if (lot == null) return;
    await widget.onAction(() async {
      await PermissionService.setIsActiveForCanBidOnLot(
        lotId: lot.id,
        isActive: false,
      );
      await AuctionLogService.append(
        auctionId: widget.auction.id,
        lotId: lot.id,
        action: AuctionLogActions.biddingPaused,
        performedBy: widget.adminUid,
        details: const {},
      );
    });
  }

  Future<void> _resume() async {
    final lot = widget.activeLot;
    if (lot == null) return;
    await widget.onAction(() async {
      await PermissionService.setIsActiveForCanBidOnLot(
        lotId: lot.id,
        isActive: true,
      );
      await AuctionLogService.append(
        auctionId: widget.auction.id,
        lotId: lot.id,
        action: AuctionLogActions.biddingResumed,
        performedBy: widget.adminUid,
        details: const {},
      );
    });
  }

  Future<void> _emergencyClose(BuildContext context) async {
    final lot = widget.activeLot;
    if (lot == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isArabic ? 'إغلاق طارئ' : 'Emergency close'),
        content: Text(
          widget.isArabic
              ? 'إيقاف الجلسة وإغلاق العنصر إدارياً دون تسوية المزايدة عبر السحابة.'
              : 'End session and mark lot closed administratively (no cloud finalize).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(widget.isArabic ? 'إغلاق' : 'Force close'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    await widget.onAction(() async {
      await LotService.endLotSession(
        lotId: lot.id,
        auctionId: widget.auction.id,
        performedBy: widget.adminUid,
        finalStatus: LotStatus.closed,
      );
    });
  }

  String _countdown(AuctionLot lot) {
    final diff = lot.endTime.difference(_now);
    if (diff.isNegative) {
      return widget.isArabic ? 'انتهى' : 'Ended';
    }
    final h = diff.inHours.toString().padLeft(2, '0');
    final m = (diff.inMinutes % 60).toString().padLeft(2, '0');
    final s = (diff.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final lot = widget.activeLot;
    final a = widget.auction;
    final ar = widget.isArabic;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: lot != null ? Colors.red.shade50 : Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ar ? 'العنصر النشط (مباشر)' : 'Active lot (live)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: lot != null ? Colors.red.shade900 : Colors.grey.shade700,
                  ),
            ),
            const SizedBox(height: 10),
            if (lot == null)
              Text(
                ar ? 'لا يوجد عنصر نشط' : 'No active lot',
                style: TextStyle(color: Colors.grey.shade600),
              )
            else ...[
              Text(lot.title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 17)),
              const SizedBox(height: 6),
              Text(
                '${ar ? 'أعلى مزايدة' : 'Highest'}: ${lot.highestBid ?? '—'}',
              ),
              Text(
                '${ar ? 'المزايد' : 'Bidder'}: ${lot.highestBidderId ?? '—'}',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                '${ar ? 'العد التنازلي' : 'Countdown'}: ${_countdown(lot)}',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.red.shade800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                DateFormat.yMMMd().add_Hm().format(lot.endTime.toLocal()),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              if (a.status != AuctionStatus.live)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    ar
                        ? 'المزاد ليس في وضع مباشر — المزايدة يجب أن تكون متوقفة منطقياً.'
                        : 'Auction is not live — bidding should not run.',
                    style: TextStyle(color: Colors.orange.shade900, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: a.status != AuctionStatus.live ? null : _pause,
                    child: Text(ar ? 'إيقاف مؤقت' : 'Pause bidding'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: a.status != AuctionStatus.live ? null : _resume,
                    child: Text(ar ? 'استئناف' : 'Resume'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.deepOrange,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _emergencyClose(context),
                    child: Text(ar ? 'إغلاق طارئ' : 'Emergency close'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
