import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

class AuctionDeposit {
  const AuctionDeposit({
    required this.id,
    required this.userId,
    required this.auctionId,
    required this.lotId,
    required this.amount,
    required this.type,
    required this.paymentStatus,
    required this.paymentGateway,
    this.transactionId,
    this.paidAt,
    this.refundedAt,
    required this.createdAt,
  });

  final String id;
  final String userId;
  final String auctionId;
  final String lotId;
  final double amount;
  final DepositType type;
  final DepositPaymentStatus paymentStatus;
  final String paymentGateway;
  final String? transactionId;
  final DateTime? paidAt;
  final DateTime? refundedAt;
  final DateTime createdAt;

  /// One holding row per user per lot (recommended for rule checks & transactions).
  static String documentId(String userId, String lotId) => '${userId}_$lotId';

  bool get isPaid => paymentStatus == DepositPaymentStatus.paid;

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'auctionId': auctionId,
      'lotId': lotId,
      'amount': amount,
      'type': type.firestoreValue,
      'paymentStatus': paymentStatus.firestoreValue,
      'paymentGateway': paymentGateway,
      if (transactionId != null) 'transactionId': transactionId,
      if (paidAt != null) 'paidAt': Timestamp.fromDate(paidAt!),
      if (refundedAt != null) 'refundedAt': Timestamp.fromDate(refundedAt!),
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  static AuctionDeposit fromFirestore(String id, Map<String, dynamic> data) {
    return AuctionDeposit(
      id: id,
      userId: auctionReadString(data['userId']),
      auctionId: auctionReadString(data['auctionId']),
      lotId: auctionReadString(data['lotId']),
      amount: auctionReadDouble(data['amount']),
      type: DepositType.fromFirestore(data['type']?.toString()),
      paymentStatus:
          DepositPaymentStatus.fromFirestore(data['paymentStatus']?.toString()),
      paymentGateway: auctionReadString(data['paymentGateway'], 'MyFatoorah'),
      transactionId: data['transactionId']?.toString(),
      paidAt: auctionReadDateTime(data['paidAt']),
      refundedAt: auctionReadDateTime(data['refundedAt']),
      createdAt: auctionReadDateTime(data['createdAt']) ?? DateTime.now(),
    );
  }
}
