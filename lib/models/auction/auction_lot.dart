import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/config/auction_read_compat.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

/// Authoritative auction lot (`lots/{id}`).
///
/// Firestore field names (canonical):
/// - [endsAt], [currentHighBid], [currentHighBidderId]
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
    required this.endsAt,
    required this.status,
    this.currentHighBid,
    this.currentHighBidderId,
    this.bidCount = 0,
    this.winnerId,
    this.finalPrice,
    this.finalizedAt,
    this.sellerApprovalStatus,
    this.adminApproved,
    this.sellerApprovalAt,
    this.adminDecisionAt,
    this.rejectionReason,
    required this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String auctionId;
  final String title;
  final String description;
  final String? propertyId;
  final String? image;
  final String? location;
  final double startingPrice;
  final double minIncrement;
  final DepositType depositType;
  final double depositValue;
  final DateTime startTime;
  final DateTime endsAt;
  final LotStatus status;
  final double? currentHighBid;
  final String? currentHighBidderId;
  final int bidCount;
  final String? winnerId;
  final double? finalPrice;
  final DateTime? finalizedAt;
  final LotSellerApprovalStatus? sellerApprovalStatus;
  final bool? adminApproved;
  final DateTime? sellerApprovalAt;
  final DateTime? adminDecisionAt;
  /// e.g. `approval_timeout`, `admin_rejected`, `seller_rejected` when [status] is rejected.
  final String? rejectionReason;
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
      'endsAt': Timestamp.fromDate(endsAt),
      'status': status.firestoreValue,
      if (currentHighBid != null) 'currentHighBid': currentHighBid,
      if (currentHighBidderId != null && currentHighBidderId!.isNotEmpty)
        'currentHighBidderId': currentHighBidderId,
      'bidCount': bidCount,
      if (winnerId != null && winnerId!.isNotEmpty) 'winnerId': winnerId,
      if (finalPrice != null) 'finalPrice': finalPrice,
      if (finalizedAt != null) 'finalizedAt': Timestamp.fromDate(finalizedAt!),
      if (sellerApprovalStatus != null)
        'sellerApprovalStatus': sellerApprovalStatus!.firestoreValue,
      if (adminApproved != null) 'adminApproved': adminApproved,
      if (sellerApprovalAt != null)
        'sellerApprovalAt': Timestamp.fromDate(sellerApprovalAt!),
      if (adminDecisionAt != null)
        'adminDecisionAt': Timestamp.fromDate(adminDecisionAt!),
      if (rejectionReason != null && rejectionReason!.trim().isNotEmpty)
        'rejectionReason': rejectionReason!.trim(),
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  static AuctionLot fromFirestore(String id, Map<String, dynamic> data) {
    final hbCanon = data['currentHighBid'];
    final hbLegacy = kAuctionReadLegacyLotFields ? data['highestBid'] : null;
    final highRaw = hbCanon ?? hbLegacy;
    final double? highBid =
        highRaw is num && highRaw.isFinite ? highRaw.toDouble() : null;

    final bidderCanon = data['currentHighBidderId']?.toString();
    final bidderLegacy =
        kAuctionReadLegacyLotFields ? data['highestBidderId']?.toString() : null;
    final bidder = (bidderCanon != null && bidderCanon.isNotEmpty)
        ? bidderCanon
        : (bidderLegacy != null && bidderLegacy.isNotEmpty)
            ? bidderLegacy
            : null;

    final endsCanon = auctionReadDateTime(data['endsAt']);
    final endsLegacy =
        kAuctionReadLegacyLotFields ? auctionReadDateTime(data['endTime']) : null;
    final ends = endsCanon ?? endsLegacy ?? DateTime.now();

    final bc = data['bidCount'];
    final bidCount = bc is int
        ? bc
        : bc is num
            ? bc.round()
            : 0;

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
      endsAt: ends,
      status: LotStatus.fromFirestore(data['status']?.toString()),
      currentHighBid: highBid,
      currentHighBidderId: bidder != null && bidder.isNotEmpty ? bidder : null,
      bidCount: bidCount,
      winnerId: () {
        final w = data['winnerId']?.toString().trim();
        return w != null && w.isNotEmpty ? w : null;
      }(),
      finalPrice: () {
        final fp = data['finalPrice'];
        return fp is num && fp.isFinite ? fp.toDouble() : null;
      }(),
      finalizedAt: auctionReadDateTime(data['finalizedAt']),
      sellerApprovalStatus:
          LotSellerApprovalStatus.fromFirestore(data['sellerApprovalStatus']?.toString()),
      adminApproved: () {
        final a = data['adminApproved'];
        if (a is bool) return a;
        return null;
      }(),
      sellerApprovalAt: auctionReadDateTime(data['sellerApprovalAt']),
      adminDecisionAt: auctionReadDateTime(data['adminDecisionAt']),
      rejectionReason: () {
        final r = data['rejectionReason']?.toString().trim();
        return r != null && r.isNotEmpty ? r : null;
      }(),
      createdAt: auctionReadDateTime(data['createdAt']) ?? DateTime.now(),
      updatedAt: auctionReadDateTime(data['updatedAt']),
    );
  }

  String get listingDocumentId {
    final p = propertyId?.trim();
    if (p != null && p.isNotEmpty) return p;
    return id;
  }

  double minimumNextBid() {
    final h = currentHighBid;
    if (h == null || h <= 0) return startingPrice;
    return h + minIncrement;
  }
}
