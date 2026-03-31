import 'package:flutter/material.dart';

import 'package:aqarai_app/models/auction/auction.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/models/auction/lot_permission.dart';
import 'package:aqarai_app/services/auction/auction_log_service.dart';
import 'package:aqarai_app/services/auction/permission_service.dart';

String _maskUid(String uid) {
  if (uid.length <= 8) return uid;
  return '${uid.substring(0, 4)}…${uid.substring(uid.length - 4)}';
}

/// Per-bidder controls for the active lot (block / re-enable / remove).
class UserControlSection extends StatelessWidget {
  const UserControlSection({
    super.key,
    required this.auction,
    required this.activeLot,
    required this.adminUid,
    required this.isArabic,
    required this.onAction,
  });

  final Auction auction;
  final AuctionLot activeLot;
  final String adminUid;
  final bool isArabic;
  final Future<void> Function(Future<void> Function() run) onAction;

  bool get _sessionLive =>
      auction.status == AuctionStatus.live &&
      activeLot.status == LotStatus.active;

  Future<void> _block(BuildContext context, LotPermission p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isArabic ? 'حظر المزايد' : 'Block bidder'),
        content: Text(_maskUid(p.userId)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isArabic ? 'حظر' : 'Block'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    await onAction(() async {
      await PermissionService.revokeCanBid(userId: p.userId, lotId: p.lotId);
      await AuctionLogService.append(
        auctionId: auction.id,
        lotId: activeLot.id,
        action: AuctionLogActions.userBlocked,
        performedBy: adminUid,
        details: {'userId': p.userId},
      );
    });
  }

  Future<void> _remove(BuildContext context, LotPermission p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isArabic ? 'إزالة من العنصر' : 'Remove from lot'),
        content: Text(_maskUid(p.userId)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isArabic ? 'إزالة' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    await onAction(() async {
      await PermissionService.deletePermissionDocument(
        userId: p.userId,
        lotId: p.lotId,
      );
      await AuctionLogService.append(
        auctionId: auction.id,
        lotId: activeLot.id,
        action: AuctionLogActions.permissionRevoked,
        performedBy: adminUid,
        details: {'userId': p.userId, 'removed': true},
      );
    });
  }

  Future<void> _enable(LotPermission p) async {
    await onAction(() async {
      await PermissionService.enableBidderOnLot(
        userId: p.userId,
        lotId: p.lotId,
        auctionId: auction.id,
        isActive: _sessionLive,
      );
      await AuctionLogService.append(
        auctionId: auction.id,
        lotId: activeLot.id,
        action: AuctionLogActions.permissionGranted,
        performedBy: adminUid,
        details: {'userId': p.userId},
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'التحكم بالمزايدين' : 'Bidder control',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            StreamBuilder<List<LotPermission>>(
              stream: PermissionService.watchPermissionsForLot(activeLot.id),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('${snap.error}',
                      style: const TextStyle(color: Colors.red));
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snap.data!;
                if (list.isEmpty) {
                  return Text(
                    isArabic ? 'لا صلاحيات مسجلة لهذا العنصر' : 'No permissions',
                    style: TextStyle(color: Colors.grey.shade600),
                  );
                }
                list.sort((a, b) => a.userId.compareTo(b.userId));
                return Column(
                  children: list.map((p) {
                    return ListTile(
                      dense: true,
                      title: Text(_maskUid(p.userId)),
                      subtitle: Text(
                        'canBid: ${p.canBid} · live: ${p.isActive}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          if (p.canBid)
                            TextButton(
                              onPressed: () => _block(context, p),
                              child: Text(isArabic ? 'حظر' : 'Block'),
                            )
                          else
                            TextButton(
                              onPressed: () => _enable(p),
                              child: Text(
                                isArabic ? 'تفعيل' : 'Enable',
                                style: const TextStyle(color: Colors.green),
                              ),
                            ),
                          TextButton(
                            onPressed: () => _remove(context, p),
                            child: Text(
                              isArabic ? 'إزالة' : 'Remove',
                              style: TextStyle(color: Colors.orange.shade800),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
