import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_utils.dart';

/// Catalog row from `public_lots` (safe fields only; synced from `lots`).
class PublicAuctionLot {
  const PublicAuctionLot({
    required this.id,
    required this.auctionId,
    required this.title,
    this.image,
    this.location,
    this.propertyId,
    required this.startingPrice,
    required this.minIncrement,
    this.depositType = DepositType.fixed,
    this.depositValue = 0,
    required this.startTime,
    this.endsAt,
    this.currentHighBid,
    this.currentHighBidderId,
    this.bidCount = 0,
    required this.displayStatus,
    this.sellerApprovalStatus,
    this.adminApproved,
    this.rejectionReason,
  });

  final String id;
  final String auctionId;
  final String title;
  final String? image;
  final String? location;
  final String? propertyId;
  final double startingPrice;
  final double minIncrement;
  final DepositType depositType;
  final double depositValue;
  final DateTime startTime;

  /// Live end time when synced from source lot (`endsAt`).
  final DateTime? endsAt;
  final double? currentHighBid;
  final String? currentHighBidderId;
  final int bidCount;

  /// `upcoming` | `active` | `closed` | `sold` | `pending_admin_review` | … (internal `pending` → `upcoming` on sync).
  final String displayStatus;

  final LotSellerApprovalStatus? sellerApprovalStatus;
  final bool? adminApproved;
  final String? rejectionReason;

  /// Target for [PropertyDetailsPage] when [propertyId] is set; else lot doc id.
  String get listingDocumentId {
    final p = propertyId?.trim();
    if (p != null && p.isNotEmpty) return p;
    return id;
  }

  static PublicAuctionLot fromFirestore(String id, Map<String, dynamic> data) {
    final st = auctionReadString(data['status']);
    final bc = data['bidCount'];
    final bidCount = bc is int
        ? bc
        : bc is num
            ? bc.round()
            : 0;
    final ch = data['currentHighBid'];
    final double? currentHigh =
        ch is num && ch.isFinite ? ch.toDouble() : null;
    final bidder = data['currentHighBidderId']?.toString().trim();
    return PublicAuctionLot(
      id: id,
      auctionId: auctionReadString(data['auctionId']),
      title: auctionReadString(data['title']),
      image: _optString(data['image']),
      location: _optString(data['location']),
      propertyId: _optString(data['propertyId']),
      startingPrice: auctionReadDouble(data['startingPrice']),
      minIncrement: auctionReadDouble(data['minIncrement']),
      depositType: DepositType.fromFirestore(data['depositType']?.toString()),
      depositValue: auctionReadDouble(data['depositValue']),
      startTime: auctionReadDateTime(data['startTime']) ?? DateTime.now(),
      endsAt: auctionReadDateTime(data['endsAt']),
      currentHighBid: currentHigh,
      currentHighBidderId:
          (bidder != null && bidder.isNotEmpty) ? bidder : null,
      bidCount: bidCount,
      displayStatus: st.isNotEmpty ? st : 'upcoming',
      sellerApprovalStatus:
          LotSellerApprovalStatus.fromFirestore(data['sellerApprovalStatus']?.toString()),
      adminApproved: () {
        final a = data['adminApproved'];
        if (a is bool) return a;
        return null;
      }(),
      rejectionReason: () {
        final r = data['rejectionReason']?.toString().trim();
        return r != null && r.isNotEmpty ? r : null;
      }(),
    );
  }

  static String? _optString(dynamic v) {
    final s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }
}
