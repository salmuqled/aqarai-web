// Chalet booking financial rows: Firestore read + admin callable for payout.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

abstract final class ChaletBookingTransactionService {
  ChaletBookingTransactionService._();

  static const String collection = 'transactions';
  static const String sourceChaletDaily = 'chalet_daily';

  static FirebaseFunctions _functions() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Admin list: chalet daily rows, newest first.
  static Query<Map<String, dynamic>> adminChaletDailyQuery({int limit = 200}) {
    return FirebaseFirestore.instance
        .collection(collection)
        .where('source', isEqualTo: sourceChaletDaily)
        .orderBy('createdAt', descending: true)
        .limit(limit);
  }

  /// Admin payout queue: pending bank transfer only.
  static Query<Map<String, dynamic>> adminChaletDailyPendingPayoutsQuery({
    int limit = 200,
  }) {
    return FirebaseFirestore.instance
        .collection(collection)
        .where('source', isEqualTo: sourceChaletDaily)
        .where('payoutStatus', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .limit(limit);
  }

  /// Owner list: own chalet daily rows, newest first.
  static Query<Map<String, dynamic>> ownerChaletDailyQuery(
    String ownerUid, {
    int limit = 200,
  }) {
    return ownerDashboardTransactionsQuery(ownerUid, limit: limit);
  }

  /// Owner dashboard: same index as daily list; cap [limit] for client-side aggregates.
  static Query<Map<String, dynamic>> ownerDashboardTransactionsQuery(
    String ownerUid, {
    int limit = 400,
  }) {
    return FirebaseFirestore.instance
        .collection(collection)
        .where('ownerId', isEqualTo: ownerUid)
        .where('source', isEqualTo: sourceChaletDaily)
        .orderBy('createdAt', descending: true)
        .limit(limit);
  }

  static Future<void> markPayoutPaid({
    required String transactionId,
    String? notes,
    String? payoutReference,
  }) async {
    final callable =
        _functions().httpsCallable('markChaletBookingTransactionPaid');
    await callable.call<void>({
      'transactionId': transactionId,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      if (payoutReference != null && payoutReference.trim().isNotEmpty)
        'payoutReference': payoutReference.trim(),
    });
  }

  /// Admin: record guest refund on ledger only (callable applies cancellation policy).
  static Future<Map<String, dynamic>> processRefund({
    required String transactionId,
    String? refundReference,
  }) async {
    final callable = _functions().httpsCallable('processChaletBookingRefund');
    final res = await callable.call<Map<String, dynamic>>({
      'transactionId': transactionId,
      if (refundReference != null && refundReference.trim().isNotEmpty)
        'refundReference': refundReference.trim(),
    });
    return Map<String, dynamic>.from(res.data);
  }
}
