import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';

/// Localized title + body for a rejected auction lot (`rejectionReason` from Firestore).
(String title, String body) auctionLotRejectionCopy(
  AppLocalizations loc,
  String? rejectionReason,
) {
  switch (rejectionReason) {
    case LotRejectionReason.approvalTimeout:
      return (
        loc.auctionLotRejectedTimeoutTitle,
        loc.auctionLotRejectedTimeoutBody,
      );
    case LotRejectionReason.adminRejected:
      return (
        loc.auctionLotRejectedByAdminTitle,
        loc.auctionLotRejectedByAdminBody,
      );
    case LotRejectionReason.sellerRejected:
      return (
        loc.auctionLotRejectedBySellerTitle,
        loc.auctionLotRejectedBySellerBody,
      );
    default:
      return (
        loc.auctionLotRejectedManualTitle,
        loc.auctionLotRejectedManualBody,
      );
  }
}

/// Prominent notice when a lot is `rejected` (timeout vs manual variants).
class AuctionLotRejectionStrip extends StatelessWidget {
  const AuctionLotRejectionStrip({
    super.key,
    required this.rejectionReason,
    this.dense = false,
  });

  final String? rejectionReason;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    if (loc == null) return const SizedBox.shrink();
    final (title, body) = auctionLotRejectionCopy(loc, rejectionReason);
    final isTimeout = rejectionReason == LotRejectionReason.approvalTimeout;
    final bg = isTimeout ? Colors.deepOrange.shade50 : Colors.red.shade50;
    final fg = isTimeout ? Colors.deepOrange.shade900 : Colors.red.shade900;
    final icon = isTimeout ? Icons.timer_off_outlined : Icons.cancel_outlined;

    return Material(
      color: bg,
      elevation: dense ? 0 : 1,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: dense ? 10 : 12,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: fg, size: dense ? 22 : 24),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w800,
                      fontSize: dense ? 14 : 15,
                    ),
                  ),
                  SizedBox(height: dense ? 4 : 6),
                  Text(
                    body,
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.92),
                      height: 1.35,
                      fontSize: dense ? 13 : 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
