import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

class Auction {
  const Auction({
    required this.id,
    required this.title,
    this.description = '',
    required this.ministryApprovalNumber,
    required this.startDate,
    required this.endDate,
    required this.status,
    required this.createdBy,
    required this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String description;
  final String ministryApprovalNumber;
  final DateTime startDate;
  final DateTime endDate;
  final AuctionStatus status;
  final String createdBy;
  final DateTime createdAt;
  final DateTime? updatedAt;

  Map<String, dynamic> toFirestore() {
    return {
      'title': title,
      if (description.trim().isNotEmpty) 'description': description.trim(),
      'ministryApprovalNumber': ministryApprovalNumber,
      'startDate': Timestamp.fromDate(startDate),
      'endDate': Timestamp.fromDate(endDate),
      'status': status.firestoreValue,
      'createdBy': createdBy,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  static Auction fromFirestore(String id, Map<String, dynamic> data) {
    final start = auctionReadDateTime(data['startDate']) ?? DateTime.now();
    final end = auctionReadDateTime(data['endDate']) ?? start;
    final created = auctionReadDateTime(data['createdAt']) ?? DateTime.now();
    return Auction(
      id: id,
      title: auctionReadString(data['title']),
      description: auctionReadString(data['description']),
      ministryApprovalNumber: auctionReadString(data['ministryApprovalNumber']),
      startDate: start,
      endDate: end,
      status: AuctionStatus.fromFirestore(data['status']?.toString()),
      createdBy: auctionReadString(data['createdBy']),
      createdAt: created,
      updatedAt: auctionReadDateTime(data['updatedAt']),
    );
  }

  Auction copyWith({
    String? title,
    String? description,
    String? ministryApprovalNumber,
    DateTime? startDate,
    DateTime? endDate,
    AuctionStatus? status,
    DateTime? updatedAt,
  }) {
    return Auction(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      ministryApprovalNumber:
          ministryApprovalNumber ?? this.ministryApprovalNumber,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      status: status ?? this.status,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
