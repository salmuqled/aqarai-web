import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/models/auction/auction_bid.dart';
import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';
import 'package:aqarai_app/models/auction/auction_participant.dart';
import 'package:aqarai_app/models/auction/lot_permission.dart';
import 'package:aqarai_app/services/auction/deposit_service.dart';

/// Bid reads + eligibility preview. **Writes:** only via Cloud Function [placeAuctionBid].
abstract final class BidService {
  BidService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static FirebaseFunctions _functions() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// UUID v4 for [placeBid] idempotency (must match Cloud Function validation).
  static String newClientRequestId() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = '0123456789abcdef';
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) sb.write('-');
      sb.write(hex[b[i] >> 4]);
      sb.write(hex[b[i] & 0x0f]);
    }
    return sb.toString();
  }

  static CollectionReference<Map<String, dynamic>> _bidsSub(String lotId) =>
      _db
          .collection(AuctionFirestorePaths.lots)
          .doc(lotId)
          .collection('bids');

  /// Latest bids for one lot (`lots/{lotId}/bids`), ordered by [createdAt] only.
  static Stream<List<AuctionBid>> watchBidsForLot(
    String lotId, {
    int limit = 100,
  }) {
    return _bidsSub(lotId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => AuctionBid.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  /// Admin monitor: latest bids across an auction (collection group `bids`).
  static Stream<List<AuctionBid>> watchBidsForAuction(
    String auctionId, {
    int limit = 20,
  }) {
    return _db
        .collectionGroup('bids')
        .where('auctionId', isEqualTo: auctionId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => AuctionBid.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  /// Client-side preview only; server re-validates in [placeAuctionBid].
  static Future<BidEligibility> checkEligibility({
    required String userId,
    required String auctionId,
    required String lotId,
    required double amount,
  }) async {
    final pubSnap =
        await _db.collection(AuctionFirestorePaths.publicLots).doc(lotId).get();
    if (!pubSnap.exists || pubSnap.data() == null) {
      return BidEligibility.fail(BidRejectionReason.lotNotFound);
    }
    final pub = pubSnap.data()!;
    final pubStatus = pub['status']?.toString() ?? '';
    if (pubStatus != 'active') {
      return BidEligibility.fail(BidRejectionReason.lotNotLive);
    }
    final start = pub['startingPrice'];
    final startingPrice =
        start is num && start.isFinite ? start.toDouble() : 0.0;
    if (amount < startingPrice) {
      return BidEligibility.fail(BidRejectionReason.belowMinimum);
    }

    final partRef = _db
        .collection(AuctionFirestorePaths.participants)
        .doc(AuctionParticipant.documentId(userId, auctionId));
    final partSnap = await partRef.get();
    if (!partSnap.exists || partSnap.data() == null) {
      return BidEligibility.fail(BidRejectionReason.notRegistered);
    }
    final part = AuctionParticipant.fromFirestore(partSnap.id, partSnap.data()!);
    if (!part.isApproved) {
      return BidEligibility.fail(BidRejectionReason.participantNotApproved);
    }

    final permRef = _db
        .collection(AuctionFirestorePaths.lotPermissions)
        .doc(LotPermission.documentId(userId, lotId));
    final permSnap = await permRef.get();
    if (!permSnap.exists || permSnap.data() == null) {
      return BidEligibility.fail(BidRejectionReason.noPermission);
    }
    final perm = LotPermission.fromFirestore(permSnap.id, permSnap.data()!);
    if (!perm.canBid || !perm.isActive) {
      return BidEligibility.fail(BidRejectionReason.permissionInactive);
    }

    final dep = await DepositService.getDeposit(userId: userId, lotId: lotId);
    if (dep == null || !dep.isPaid) {
      return BidEligibility.fail(BidRejectionReason.depositNotPaid);
    }

    return const BidEligibility.ok();
  }

  static String mapPlaceBidFunctionsError(
    FirebaseFunctionsException e, {
    required bool arabic,
  }) {
    final code = e.code;
    final m = (e.message ?? '').toLowerCase();

    if (code == 'failed-precondition') {
      if (m.contains('end') ||
          m.contains('ended') ||
          m.contains('after the lot') ||
          m.contains('bidding period')) {
        return arabic ? 'انتهى المزاد' : 'Auction ended';
      }
      if (m.contains('greater') ||
          m.contains('minimum') ||
          m.contains('increment') ||
          m.contains('opening bid')) {
        return arabic ? 'المزايدة أقل من المطلوب' : 'Bid too low';
      }
      if (m.contains('not open') ||
          m.contains('not live') ||
          m.contains('deposit') ||
          m.contains('permission') ||
          m.contains('registered')) {
        return arabic ? 'لا يمكن المزايدة حالياً' : 'Bidding not allowed right now';
      }
      if (m.contains('one bid per second') ||
          m.contains('per second') ||
          m.contains('wait at least') ||
          m.contains('between bids')) {
        return arabic ? 'انتظر قليلاً قبل المزايدة مرة أخرى' : 'Wait before bidding again';
      }
      if (m.contains('clientrequestid') ||
          m.contains('client request id') ||
          m.contains('different amount')) {
        return arabic ? 'طلب مزايدة مكرر أو غير صالح' : 'Duplicate or invalid bid request';
      }
      return arabic ? 'تعذّر تنفيذ المزايدة' : 'Could not place bid';
    }
    if (code == 'permission-denied') {
      return arabic ? 'غير مصرّح' : 'Not authorized';
    }
    if (code == 'resource-exhausted') {
      if (m.contains('too many bids') || m.contains('last 60')) {
        return arabic
            ? 'عدد كبير من المزايدات — انتظر قليلاً'
            : 'Too many bids in a short time — try again shortly';
      }
      return arabic ? 'انتظر قليلاً قبل المزايدة مرة أخرى' : 'Too many bids — try again shortly';
    }
    if (code == 'not-found') {
      return arabic ? 'العنصر غير موجود' : 'Not found';
    }
    if (code == 'invalid-argument') {
      if (m.contains('clientrequestid') || m.contains('uuid')) {
        return arabic
            ? 'معرّف الطلب غير صالح (UUID)'
            : 'Invalid client request id (UUID required)';
      }
      return arabic ? 'بيانات غير صالحة' : 'Invalid request';
    }
    if (code == 'unauthenticated') {
      return arabic ? 'يجب تسجيل الدخول' : 'Sign in required';
    }
    return arabic
        ? (e.message ?? 'حدث خطأ')
        : (e.message ?? 'Something went wrong');
  }

  static Future<BidPlacementResult> placeBid({
    required String auctionId,
    required String lotId,
    required double amount,
    bool arabicMessages = true,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return BidPlacementResult.error(
        arabicMessages ? 'يجب تسجيل الدخول' : 'You must be signed in',
      );
    }

    try {
      final callable = _functions().httpsCallable('placeAuctionBid');
      final res = await callable.call<dynamic>({
        'auctionId': auctionId,
        'lotId': lotId,
        'amount': amount,
        'clientRequestId': newClientRequestId(),
      });

      final raw = res.data;
      if (raw is! Map) {
        return BidPlacementResult.error('Invalid response from server');
      }
      final data = Map<String, dynamic>.from(raw);
      if (data['success'] == true) {
        final bidId = data['bidId']?.toString() ?? '';
        final hb = data['currentHighBid'];
        final highest = hb is num ? hb.toDouble() : amount;
        final le = data['lotEndTimeMs'];
        final lotEndMs = le is num ? le.round() : null;
        return BidPlacementResult.success(
          bidId,
          currentHighBid: highest,
          antiSnipeExtended: data['antiSnipeExtended'] == true,
          lotEndTimeMs: lotEndMs,
        );
      }
      return BidPlacementResult.error(
        arabicMessages
            ? 'تعذّر تنفيذ المزايدة'
            : (data['message']?.toString() ?? 'Unknown error'),
      );
    } on FirebaseFunctionsException catch (e) {
      return BidPlacementResult.error(
        mapPlaceBidFunctionsError(e, arabic: arabicMessages),
      );
    } catch (e) {
      return BidPlacementResult.error(
        arabicMessages ? 'حدث خطأ غير متوقع' : e.toString(),
      );
    }
  }
}

enum BidRejectionReason {
  lotNotFound,
  lotNotLive,
  belowMinimum,
  notRegistered,
  participantNotApproved,
  noPermission,
  permissionInactive,
  depositNotPaid,
}

class BidEligibility {
  const BidEligibility._(this.ok, this.reason);

  final bool ok;
  final BidRejectionReason? reason;

  const BidEligibility.ok() : this._(true, null);
  const BidEligibility.fail(BidRejectionReason r) : this._(false, r);
}

class BidPlacementResult {
  const BidPlacementResult._({
    this.success = false,
    this.bidId,
    this.currentHighBid,
    this.antiSnipeExtended,
    this.lotEndTimeMs,
    this.rejection,
    this.errorMessage,
  });

  final bool success;
  final String? bidId;
  final double? currentHighBid;
  final bool? antiSnipeExtended;
  final int? lotEndTimeMs;
  final BidRejectionReason? rejection;
  final String? errorMessage;

  factory BidPlacementResult.success(
    String id, {
    double? currentHighBid,
    bool? antiSnipeExtended,
    int? lotEndTimeMs,
  }) =>
      BidPlacementResult._(
        success: true,
        bidId: id,
        currentHighBid: currentHighBid,
        antiSnipeExtended: antiSnipeExtended,
        lotEndTimeMs: lotEndTimeMs,
      );

  factory BidPlacementResult.rejected(BidRejectionReason r) =>
      BidPlacementResult._(rejection: r);

  factory BidPlacementResult.error(String msg) =>
      BidPlacementResult._(errorMessage: msg);
}
