import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

class AuctionLot {
  const AuctionLot({
    required this.id,
    required this.auctionId,
    required this.title,
    required this.description,
    this.propertyId,
    this.image,
    this.location,
    required this.startingPrice,
    required this.minIncrement,
    required this.depositType,
    required this.depositValue,
    required this.startTime,
    required this.endTime,
    required this.status,
    this.highestBid,
    this.highestBidderId,
    this.winnerId,
    this.finalPrice,
    this.finalizedAt,
    required this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String auctionId;
  final String title;
  final String description;
  /// When set, points at `properties/{propertyId}` for listing details.
  final String? propertyId;
  final String? image;
  final String? location;
  final double startingPrice;
  final double minIncrement;
  final DepositType depositType;
  final double depositValue;
  final DateTime startTime;
  final DateTime endTime;
  final LotStatus status;
  final double? highestBid;
  final String? highestBidderId;
  /// Set when lot is finalized with a winning bid (`sold`).
  final String? winnerId;
  final double? finalPrice;
  final DateTime? finalizedAt;
  final DateTime createdAt;
  final DateTime? updatedAt;

  Map<String, dynamic> toFirestore() {
    return {
      'auctionId': auctionId,
      'title': title,
      'description': description,
      if (propertyId != null && propertyId!.trim().isNotEmpty)
        'propertyId': propertyId!.trim(),
      if (image != null && image!.trim().isNotEmpty) 'image': image!.trim(),
      if (location != null && location!.trim().isNotEmpty)
        'location': location!.trim(),
      'startingPrice': startingPrice,
      'minIncrement': minIncrement,
      'depositType': depositType.firestoreValue,
      'depositValue': depositValue,
      'startTime': Timestamp.fromDate(startTime),
      'endTime': Timestamp.fromDate(endTime),
      'status': status.firestoreValue,
      if (highestBid != null) 'highestBid': highestBid,
      if (highestBidderId != null && highestBidderId!.isNotEmpty)
        'highestBidderId': highestBidderId,
      if (winnerId != null && winnerId!.isNotEmpty) 'winnerId': winnerId,
      if (finalPrice != null) 'finalPrice': finalPrice,
      if (finalizedAt != null) 'finalizedAt': Timestamp.fromDate(finalizedAt!),
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  static AuctionLot fromFirestore(String id, Map<String, dynamic> data) {
    final hb = data['highestBid'];
    final double? highBid = hb is num && hb.isFinite ? hb.toDouble() : null;
    final bidder = data['highestBidderId']?.toString();
    final winId = data['winnerId']?.toString();
    final fp = data['finalPrice'];
    final double? finalP =
        fp is num && fp.isFinite ? fp.toDouble() : null;
    final pid = data['propertyId']?.toString().trim();
    final img = data['image']?.toString().trim();
    final loc = data['location']?.toString().trim();
    return AuctionLot(
      id: id,
      auctionId: auctionReadString(data['auctionId']),
      title: auctionReadString(data['title']),
      description: auctionReadString(data['description']),
      propertyId: pid != null && pid.isNotEmpty ? pid : null,
      image: img != null && img.isNotEmpty ? img : null,
      location: loc != null && loc.isNotEmpty ? loc : null,
      startingPrice: auctionReadDouble(data['startingPrice']),
      minIncrement: auctionReadDouble(data['minIncrement']),
      depositType: DepositType.fromFirestore(data['depositType']?.toString()),
      depositValue: auctionReadDouble(data['depositValue']),
      startTime: auctionReadDateTime(data['startTime']) ?? DateTime.now(),
      endTime: auctionReadDateTime(data['endTime']) ?? DateTime.now(),
      status: LotStatus.fromFirestore(data['status']?.toString()),
      highestBid: highBid,
      highestBidderId:
          bidder != null && bidder.isNotEmpty ? bidder : null,
      winnerId: winId != null && winId.isNotEmpty ? winId : null,
      finalPrice: finalP,
      finalizedAt: auctionReadDateTime(data['finalizedAt']),
      createdAt: auctionReadDateTime(data['createdAt']) ?? DateTime.now(),
      updatedAt: auctionReadDateTime(data['updatedAt']),
    );
  }

  /// Id passed to [PropertyDetailsPage] as `propertyId` (listing doc or lot id).
  String get listingDocumentId {
    final p = propertyId?.trim();
    if (p != null && p.isNotEmpty) return p;
    return id;
  }

  /// Minimum next bid (after at least one bid), else [startingPrice].
  double minimumNextBid() {
    final h = highestBid;
    if (h == null) return startingPrice;
    return h + minIncrement;
  }
}
