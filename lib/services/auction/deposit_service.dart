import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'package:aqarai_app/models/auction/auction_deposit.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';

abstract final class DepositService {
  DepositService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AuctionFirestorePaths.deposits);

  static DocumentReference<Map<String, dynamic>> ref(String id) =>
      _col.doc(id);

  static Stream<AuctionDeposit?> watchDeposit({
    required String userId,
    required String lotId,
  }) {
    final id = AuctionDeposit.documentId(userId, lotId);
    return ref(id).snapshots().map((s) {
      if (!s.exists || s.data() == null) return null;
      return AuctionDeposit.fromFirestore(s.id, s.data()!);
    });
  }

  static Future<AuctionDeposit?> getDeposit({
    required String userId,
    required String lotId,
  }) async {
    final id = AuctionDeposit.documentId(userId, lotId);
    final s = await ref(id).get();
    if (!s.exists || s.data() == null) return null;
    return AuctionDeposit.fromFirestore(s.id, s.data()!);
  }

  /// Server callable [createAuctionDeposit]: deterministic `deposits/{userId}_{lotId}`.
  /// Idempotent — existing document is returned; never creates a second row.
  static Future<String> createAuctionDeposit({
    required String auctionId,
    required String lotId,
  }) async {
    final callable = FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('createAuctionDeposit');
    final result = await callable.call<Map<String, dynamic>>({
      'auctionId': auctionId,
      'lotId': lotId,
    });
    final data = result.data;
    final id = data['depositId']?.toString();
    if (id == null || id.isEmpty) {
      throw StateError('createAuctionDeposit returned no depositId');
    }
    return id;
  }

  /// Admin or payment webhook (via Cloud Function) should call this.
  static Future<void> updatePaymentStatus({
    required String userId,
    required String lotId,
    required DepositPaymentStatus status,
    String? transactionId,
    DateTime? paidAt,
    DateTime? refundedAt,
  }) async {
    final id = AuctionDeposit.documentId(userId, lotId);
    final map = <String, dynamic>{
      'paymentStatus': status.firestoreValue,
    };
    if (transactionId != null) map['transactionId'] = transactionId;
    if (paidAt != null) map['paidAt'] = Timestamp.fromDate(paidAt);
    if (refundedAt != null) map['refundedAt'] = Timestamp.fromDate(refundedAt);
    await ref(id).update(map);
  }
}
