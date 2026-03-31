import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/models/auction/public_auction_lot.dart';
import 'package:aqarai_app/services/auction/auction_log_service.dart';
import 'package:aqarai_app/services/auction/permission_service.dart';

abstract final class LotService {
  LotService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _lotsCol =>
      _db.collection(AuctionFirestorePaths.lots);

  static CollectionReference<Map<String, dynamic>> get _publicLotsCol =>
      _db.collection(AuctionFirestorePaths.publicLots);

  static DocumentReference<Map<String, dynamic>> ref(String lotId) =>
      _lotsCol.doc(lotId);

  /// Public catalog (guest-safe). Synced from `lots` by Cloud Function.
  static Stream<List<PublicAuctionLot>> watchPublicLotsForAuction(
    String auctionId,
  ) {
    return _publicLotsCol
        .where('auctionId', isEqualTo: auctionId)
        .orderBy('startTime')
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => PublicAuctionLot.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  /// Full [AuctionLot] stream — requires **admin** Firestore read on `lots`.
  static Stream<List<AuctionLot>> watchLotsForAdminAuction(String auctionId) {
    return _lotsCol
        .where('auctionId', isEqualTo: auctionId)
        .orderBy('startTime')
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => AuctionLot.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  static Future<AuctionLot?> getLot(String lotId) async {
    final s = await ref(lotId).get();
    if (!s.exists || s.data() == null) return null;
    return AuctionLot.fromFirestore(s.id, s.data()!);
  }

  /// Real-time single lot (e.g. live auction screen). Uses authoritative `lots`.
  ///
  /// With default Firestore rules (`lots` read: admin only), this stream works
  /// for admin clients. To support live bidders, relax rules or use a server feed.
  static Stream<AuctionLot?> watchLot(String lotId) {
    return ref(lotId).snapshots().map((s) {
      if (!s.exists || s.data() == null) return null;
      return AuctionLot.fromFirestore(s.id, s.data()!);
    });
  }

  static Future<String> createLot(AuctionLot lot) async {
    final doc = lot.id.isNotEmpty ? _lotsCol.doc(lot.id) : _lotsCol.doc();
    final toWrite = AuctionLot(
      id: doc.id,
      auctionId: lot.auctionId,
      title: lot.title,
      description: lot.description,
      propertyId: lot.propertyId,
      image: lot.image,
      location: lot.location,
      startingPrice: lot.startingPrice,
      minIncrement: lot.minIncrement,
      depositType: lot.depositType,
      depositValue: lot.depositValue,
      startTime: lot.startTime,
      endTime: lot.endTime,
      status: lot.status,
      highestBid: lot.highestBid,
      highestBidderId: lot.highestBidderId,
      winnerId: lot.winnerId,
      finalPrice: lot.finalPrice,
      finalizedAt: lot.finalizedAt,
      createdAt: lot.createdAt,
      updatedAt: lot.updatedAt,
    );
    await doc.set(toWrite.toFirestore());
    return doc.id;
  }

  static Future<void> updateLotStatus({
    required String lotId,
    required LotStatus status,
  }) async {
    await ref(lotId).update({
      'status': status.firestoreValue,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> _deactivateOtherLotsInAuction({
    required String auctionId,
    required String exceptLotId,
    required String performedBy,
  }) async {
    final snap = await _lotsCol.where('auctionId', isEqualTo: auctionId).get();
    final batch = _db.batch();
    final superseded = <String>[];
    for (final d in snap.docs) {
      if (d.id == exceptLotId) continue;
      final data = d.data();
      if (data['status'] == LotStatus.active.firestoreValue) {
        batch.update(d.reference, {
          'status': LotStatus.closed.firestoreValue,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        superseded.add(d.id);
      }
    }
    await batch.commit();
    if (superseded.isNotEmpty) {
      for (final lid in superseded) {
        await PermissionService.deactivateAllPermissionsForLot(lid);
      }
      await AuctionLogService.append(
        auctionId: auctionId,
        action: AuctionLogActions.lotsSuperseded,
        performedBy: performedBy,
        details: {
          'supersededLotIds': superseded,
          'activatedLotId': exceptLotId,
        },
      );
    }
  }

  /// Sets this lot [active], clears any other active lot in the same auction,
  /// then activates bidding permissions for [eligibleBidderUserIds].
  static Future<void> startLotSession({
    required String lotId,
    required String auctionId,
    required List<String> eligibleBidderUserIds,
    required String performedBy,
  }) async {
    await _deactivateOtherLotsInAuction(
      auctionId: auctionId,
      exceptLotId: lotId,
      performedBy: performedBy,
    );

    await ref(lotId).update({
      'status': LotStatus.active.firestoreValue,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await PermissionService.setActiveForLot(
      lotId: lotId,
      auctionId: auctionId,
      eligibleUserIds: eligibleBidderUserIds,
      isActive: true,
    );

    await AuctionLogService.append(
      auctionId: auctionId,
      lotId: lotId,
      action: AuctionLogActions.lotStarted,
      performedBy: performedBy,
      details: {'eligibleBidders': eligibleBidderUserIds.length},
    );
  }

  /// Closes the lot and clears live [isActive] flags on all lot permissions.
  static Future<void> endLotSession({
    required String lotId,
    required String auctionId,
    required String performedBy,
    LotStatus finalStatus = LotStatus.closed,
  }) async {
    await ref(lotId).update({
      'status': finalStatus.firestoreValue,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await PermissionService.deactivateAllPermissionsForLot(lotId);

    await AuctionLogService.append(
      auctionId: auctionId,
      lotId: lotId,
      action: AuctionLogActions.lotClosed,
      performedBy: performedBy,
      details: {'finalStatus': finalStatus.firestoreValue},
    );
  }

  /// Admin callable [finalizeLot]: closes lot after [endTime], sets winning bid to `won`.
  static Future<Map<String, dynamic>> finalizeLotAdmin({required String lotId}) async {
    final callable =
        FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('finalizeLot');
    final res = await callable.call<dynamic>({'lotId': lotId});
    final raw = res.data;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }
}
