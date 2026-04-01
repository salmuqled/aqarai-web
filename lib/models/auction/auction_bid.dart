import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

/// Bid document under `lots/{lotId}/bids/{bidId}`.
/// Canonical ordering field: [createdAt] (server timestamp).
class AuctionBid {
  const AuctionBid({
    required this.id,
    required this.userId,
    required this.auctionId,
    required this.lotId,
    required this.amount,
    required this.createdAt,
    required this.status,
    required this.isAutoExtended,
    this.clientRequestId,
  });

  final String id;
  final String userId;
  final String auctionId;
  final String lotId;
  final double amount;
  final DateTime createdAt;
  final BidStatus status;
  final bool isAutoExtended;

  /// Same as document id when placed via [placeAuctionBid] (UUID v4).
  final String? clientRequestId;

  /// Alias for UI sorted by time.
  DateTime get placedAt => createdAt;

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'auctionId': auctionId,
      'lotId': lotId,
      'amount': amount,
      'createdAt': Timestamp.fromDate(createdAt),
      'status': status.firestoreValue,
      'isAutoExtended': isAutoExtended,
      if (clientRequestId != null && clientRequestId!.trim().isNotEmpty)
        'clientRequestId': clientRequestId!.trim(),
    };
  }

  static AuctionBid fromFirestore(String id, Map<String, dynamic> data) {
    final created = auctionReadDateTime(data['createdAt']);
    final cr = data['clientRequestId']?.toString().trim();
    return AuctionBid(
      id: id,
      userId: auctionReadString(data['userId']),
      auctionId: auctionReadString(data['auctionId']),
      lotId: auctionReadString(data['lotId']),
      amount: auctionReadDouble(data['amount']),
      createdAt: created ?? DateTime.now(),
      status: BidStatus.fromFirestore(data['status']?.toString()),
      isAutoExtended: auctionReadBool(data['isAutoExtended']),
      clientRequestId: (cr != null && cr.isNotEmpty) ? cr : null,
    );
  }
}
