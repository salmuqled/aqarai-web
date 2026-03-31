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
    required this.displayStatus,
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

  /// `upcoming` | `active` | `closed` | `sold` (internal `pending` → `upcoming` on sync).
  final String displayStatus;

  /// Target for [PropertyDetailsPage] when [propertyId] is set; else lot doc id.
  String get listingDocumentId {
    final p = propertyId?.trim();
    if (p != null && p.isNotEmpty) return p;
    return id;
  }

  static PublicAuctionLot fromFirestore(String id, Map<String, dynamic> data) {
    final st = auctionReadString(data['status']);
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
      displayStatus: st.isNotEmpty ? st : 'upcoming',
    );
  }

  static String? _optString(dynamic v) {
    final s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }
}
