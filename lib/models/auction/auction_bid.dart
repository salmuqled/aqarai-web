import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

class AuctionBid {
  const AuctionBid({
    required this.id,
    required this.userId,
    required this.auctionId,
    required this.lotId,
    required this.amount,
    required this.timestamp,
    required this.status,
    required this.isAutoExtended,
    this.createdAt,
  });

  final String id;
  final String userId;
  final String auctionId;
  final String lotId;
  final double amount;
  final DateTime timestamp;
  final BidStatus status;
  final bool isAutoExtended;
  final DateTime? createdAt;

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'auctionId': auctionId,
      'lotId': lotId,
      'amount': amount,
      'timestamp': Timestamp.fromDate(timestamp),
      'status': status.firestoreValue,
      'isAutoExtended': isAutoExtended,
      if (createdAt != null) 'createdAt': Timestamp.fromDate(createdAt!),
    };
  }

  static AuctionBid fromFirestore(String id, Map<String, dynamic> data) {
    final ts = auctionReadDateTime(data['timestamp']) ??
        auctionReadDateTime(data['createdAt']) ??
        DateTime.now();
    return AuctionBid(
      id: id,
      userId: auctionReadString(data['userId']),
      auctionId: auctionReadString(data['auctionId']),
      lotId: auctionReadString(data['lotId']),
      amount: auctionReadDouble(data['amount']),
      timestamp: ts,
      status: BidStatus.fromFirestore(data['status']?.toString()),
      isAutoExtended: auctionReadBool(data['isAutoExtended']),
      createdAt: auctionReadDateTime(data['createdAt']),
    );
  }
}
