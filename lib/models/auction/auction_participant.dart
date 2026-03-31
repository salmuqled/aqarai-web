import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

class AuctionParticipant {
  const AuctionParticipant({
    required this.id,
    required this.userId,
    required this.auctionId,
    required this.status,
    this.approvedBy,
    this.approvedAt,
    this.notes,
    required this.createdAt,
  });

  final String id;
  final String userId;
  final String auctionId;
  final ParticipantStatus status;
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? notes;
  final DateTime createdAt;

  /// Deterministic doc id: `{userId}_{auctionId}` (Firestore-safe subset).
  static String documentId(String userId, String auctionId) =>
      '${userId}_$auctionId';

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'auctionId': auctionId,
      'status': status.firestoreValue,
      if (approvedBy != null) 'approvedBy': approvedBy,
      if (approvedAt != null) 'approvedAt': Timestamp.fromDate(approvedAt!),
      if (notes != null) 'notes': notes,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  static AuctionParticipant fromFirestore(String id, Map<String, dynamic> data) {
    return AuctionParticipant(
      id: id,
      userId: auctionReadString(data['userId']),
      auctionId: auctionReadString(data['auctionId']),
      status: ParticipantStatus.fromFirestore(data['status']?.toString()),
      approvedBy: data['approvedBy']?.toString(),
      approvedAt: auctionReadDateTime(data['approvedAt']),
      notes: data['notes']?.toString(),
      createdAt: auctionReadDateTime(data['createdAt']) ?? DateTime.now(),
    );
  }

  bool get isApproved => status == ParticipantStatus.approved;
}
