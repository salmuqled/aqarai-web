import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

class LotPermission {
  const LotPermission({
    required this.id,
    required this.userId,
    required this.lotId,
    required this.auctionId,
    required this.canBid,
    required this.isActive,
    required this.createdAt,
    this.updatedAt,
    this.lastBidAt,
  });

  final String id;
  final String userId;
  final String lotId;
  final String auctionId;
  final bool canBid;
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  /// Server-set by [placeAuctionBid] for rate limiting (min interval + bids / minute window).
  final DateTime? lastBidAt;

  static String documentId(String userId, String lotId) => '${userId}_$lotId';

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'lotId': lotId,
      'auctionId': auctionId,
      'canBid': canBid,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      if (lastBidAt != null) 'lastBidAt': Timestamp.fromDate(lastBidAt!),
    };
  }

  static LotPermission fromFirestore(String id, Map<String, dynamic> data) {
    return LotPermission(
      id: id,
      userId: auctionReadString(data['userId']),
      lotId: auctionReadString(data['lotId']),
      auctionId: auctionReadString(data['auctionId']),
      canBid: auctionReadBool(data['canBid']),
      isActive: auctionReadBool(data['isActive']),
      createdAt: auctionReadDateTime(data['createdAt']) ?? DateTime.now(),
      updatedAt: auctionReadDateTime(data['updatedAt']),
      lastBidAt: auctionReadDateTime(data['lastBidAt']),
    );
  }
}
