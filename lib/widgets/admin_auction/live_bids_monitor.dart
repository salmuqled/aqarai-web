import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/models/auction/auction_bid.dart';
import 'package:aqarai_app/services/auction/bid_service.dart';

String _maskUid(String uid) {
  if (uid.length <= 8) return uid;
  return '${uid.substring(0, 4)}…${uid.substring(uid.length - 4)}';
}

/// Live stream of latest bids for the auction.
class LiveBidsMonitor extends StatelessWidget {
  const LiveBidsMonitor({
    super.key,
    required this.auctionId,
    required this.isArabic,
  });

  final String auctionId;
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat.Hms();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'مراقبة المزايدات' : 'Live bids',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            StreamBuilder<List<AuctionBid>>(
              stream: BidService.watchBidsForAuction(auctionId, limit: 20),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Text('${snap.error}', style: const TextStyle(color: Colors.red));
                }
                if (!snap.hasData) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  );
                }
                final bids = snap.data!;
                if (bids.isEmpty) {
                  return Text(
                    isArabic ? 'لا مزايدات بعد' : 'No bids yet',
                    style: TextStyle(color: Colors.grey.shade600),
                  );
                }
                var maxAmt = bids.first.amount;
                for (final b in bids) {
                  if (b.amount > maxAmt) maxAmt = b.amount;
                }
                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: bids.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final b = bids[i];
                    final isTop = (b.amount - maxAmt).abs() < 1e-9;
                    return ListTile(
                      dense: true,
                      tileColor: isTop ? Colors.green.shade50 : null,
                      title: Text(
                        '${b.amount}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: isTop ? Colors.green.shade900 : null,
                        ),
                      ),
                      subtitle: Text(
                        '${_maskUid(b.userId)} · ${fmt.format(b.timestamp.toLocal())}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: isTop
                          ? Icon(Icons.star, color: Colors.green.shade700, size: 20)
                          : null,
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
