// Chalet booking financial rows: Firestore read + admin callable for payout.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// One page of admin ledger query results (for future pagination UI).
class AdminBookingLedgerPageBatch {
  const AdminBookingLedgerPageBatch({
    required this.documents,
    required this.limit,
    this.lastDocument,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents;
  final QueryDocumentSnapshot<Map<String, dynamic>>? lastDocument;
  final int limit;

  /// When true, callers may fetch another page with [startAfterDocument] = [lastDocument].
  bool get mayHaveMore => documents.length >= limit && lastDocument != null;
}

abstract final class ChaletBookingTransactionService {
  ChaletBookingTransactionService._();

  static const String collection = 'transactions';
  static const String sourceChaletDaily = 'chalet_daily';

  /// Default page size for admin ledger reads (keep in sync with UI until pagination ships).
  static const int adminBookingLedgerPageSizeDefault = 400;

  static FirebaseFunctions _functions() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Admin list: newest first (`createdAt` desc). Optional [startAfterDocument] for next page.
  static Query<Map<String, dynamic>> adminBookingLedgerQuery({
    int limit = adminBookingLedgerPageSizeDefault,
    DocumentSnapshot<Map<String, dynamic>>? startAfterDocument,
  }) {
    var q = FirebaseFirestore.instance
        .collection(collection)
        .orderBy('createdAt', descending: true);
    if (startAfterDocument != null) {
      q = q.startAfterDocument(startAfterDocument);
    }
    return q.limit(limit);
  }

  /// Admin payout queue: pending first, same sort as full list (`createdAt` desc).
  static Query<Map<String, dynamic>> adminBookingLedgerPendingPayoutsQuery({
    int limit = adminBookingLedgerPageSizeDefault,
    DocumentSnapshot<Map<String, dynamic>>? startAfterDocument,
  }) {
    var q = FirebaseFirestore.instance
        .collection(collection)
        .where('payoutStatus', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true);
    if (startAfterDocument != null) {
      q = q.startAfterDocument(startAfterDocument);
    }
    return q.limit(limit);
  }

  /// Fetches one page of all ledger docs (newest first). UI can pass [startAfterDocument] from a prior batch’s [AdminBookingLedgerPageBatch.lastDocument].
  static Future<AdminBookingLedgerPageBatch> fetchAdminBookingLedgerPage({
    int limit = adminBookingLedgerPageSizeDefault,
    DocumentSnapshot<Map<String, dynamic>>? startAfterDocument,
  }) async {
    final snap =
        await adminBookingLedgerQuery(limit: limit, startAfterDocument: startAfterDocument).get();
    final docs = snap.docs;
    return AdminBookingLedgerPageBatch(
      documents: docs,
      lastDocument: docs.isEmpty ? null : docs.last,
      limit: limit,
    );
  }

  /// Fetches one page of pending payout rows (same ordering as [adminBookingLedgerPendingPayoutsQuery]).
  static Future<AdminBookingLedgerPageBatch> fetchAdminBookingLedgerPendingPage({
    int limit = adminBookingLedgerPageSizeDefault,
    DocumentSnapshot<Map<String, dynamic>>? startAfterDocument,
  }) async {
    final snap = await adminBookingLedgerPendingPayoutsQuery(
      limit: limit,
      startAfterDocument: startAfterDocument,
    ).get();
    final docs = snap.docs;
    return AdminBookingLedgerPageBatch(
      documents: docs,
      lastDocument: docs.isEmpty ? null : docs.last,
      limit: limit,
    );
  }

  /// Admin list: chalet daily rows only, newest first.
  static Query<Map<String, dynamic>> adminChaletDailyQuery({int limit = 200}) {
    return FirebaseFirestore.instance
        .collection(collection)
        .where('source', isEqualTo: sourceChaletDaily)
        .orderBy('createdAt', descending: true)
        .limit(limit);
  }

  /// Admin payout queue: chalet daily pending only.
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
