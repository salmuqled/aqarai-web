import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

class AuctionLogEntry {
  const AuctionLogEntry({
    required this.id,
    required this.auctionId,
    this.lotId,
    required this.action,
    required this.performedBy,
    required this.details,
    required this.timestamp,
  });

  final String id;
  final String auctionId;
  final String? lotId;
  final String action;
  /// Admin UID or literal `system`.
  final String performedBy;
  final Map<String, dynamic> details;
  final DateTime timestamp;

  static const String performedBySystem = 'system';

  Map<String, dynamic> toFirestore() {
    return {
      'auctionId': auctionId,
      if (lotId != null && lotId!.isNotEmpty) 'lotId': lotId,
      'action': action,
      'performedBy': performedBy,
      'details': details,
      'timestamp': Timestamp.fromDate(timestamp),
    };
  }

  static AuctionLogEntry fromFirestore(String id, Map<String, dynamic> data) {
    final raw = data['details'];
    final Map<String, dynamic> det =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    return AuctionLogEntry(
      id: id,
      auctionId: auctionReadString(data['auctionId']),
      lotId: data['lotId']?.toString(),
      action: auctionReadString(data['action']),
      performedBy: auctionReadString(data['performedBy'], performedBySystem),
      details: det,
      timestamp: auctionReadDateTime(data['timestamp']) ?? DateTime.now(),
    );
  }
}
