import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/models/auction/auction.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/services/auction/auction_service.dart';
import 'package:aqarai_app/services/auction/lot_service.dart';

/// All lots for the auction with start / finalize controls.
class LotListSection extends StatelessWidget {
  const LotListSection({
    super.key,
    required this.auction,
    required this.lots,
    required this.adminUid,
    required this.isArabic,
    required this.onAction,
  });

  final Auction auction;
  final List<AuctionLot> lots;
  final String adminUid;
  final bool isArabic;
  final Future<void> Function(Future<void> Function() run) onAction;

  bool get _auctionLive => auction.status == AuctionStatus.live;

  Future<void> _startLot(BuildContext context, AuctionLot lot) async {
    if (!_auctionLive) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isArabic ? 'تشغيل العنصر' : 'Start lot'),
        content: Text(
          isArabic
              ? 'سيتم إغلاق أي عنصر نشط آخر وتفعيل المزايدة للمسجلين المعتمدين.'
              : 'Any other active lot will be closed; approved bidders will be activated for this lot.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isArabic ? 'تشغيل' : 'Start'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    await onAction(() async {
      final ids = await AuctionService.approvedParticipantUserIds(auction.id);
      await LotService.startLotSession(
        lotId: lot.id,
        auctionId: auction.id,
        eligibleBidderUserIds: ids,
        performedBy: adminUid,
      );
    });
  }

  Future<void> _closeLot(BuildContext context, AuctionLot lot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isArabic ? 'إغلاق العنصر' : 'Close lot'),
        content: Text(
          isArabic
              ? 'استدعاء التسوية النهائية (finalize). إن تعذر بسبب الوقت، يمكن الإغلاق الإداري لاحقاً.'
              : 'Call finalize (winner lock). If time has not passed, you may force-close from the safety panel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isArabic ? 'تسوية' : 'Finalize'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    await onAction(() async {
      try {
        await LotService.finalizeLotAdmin(lotId: lot.id);
      } on FirebaseFunctionsException catch (e) {
        if (!context.mounted) rethrow;
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              e.message ??
                  (isArabic
                      ? 'تعذّر التسوية — تحقق من انتهاء الوقت أو استخدم الإغلاق الطارئ'
                      : 'Finalize failed — check end time or use emergency close'),
            ),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat.yMMMd().add_Hm();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'العناصر' : 'Lots',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            if (lots.isEmpty)
              Text(
                isArabic ? 'لا توجد عناصر' : 'No lots',
                style: TextStyle(color: Colors.grey.shade600),
              )
            else
              ...lots.map((lot) {
                final active = lot.status == LotStatus.active;
                final sold = lot.status == LotStatus.sold;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: active
                        ? Colors.red.shade50
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            lot.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${isArabic ? 'الحالة' : 'Status'}: ${lot.status.firestoreValue}',
                            style: TextStyle(
                              color: active
                                  ? Colors.red.shade800
                                  : Colors.grey.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (lot.highestBid != null)
                            Text(
                              '${isArabic ? 'أعلى مزايدة' : 'High bid'}: ${lot.highestBid}',
                            ),
                          Text(
                            '${isArabic ? 'النهاية' : 'Ends'}: ${fmt.format(lot.endTime.toLocal())}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: (!_auctionLive || sold || active)
                                    ? null
                                    : () => _startLot(context, lot),
                                child: Text(isArabic ? 'تشغيل' : 'Start lot'),
                              ),
                              FilledButton.tonal(
                                onPressed: sold
                                    ? null
                                    : () => _closeLot(context, lot),
                                child: Text(isArabic ? 'تسوية / إغلاق' : 'Finalize'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
