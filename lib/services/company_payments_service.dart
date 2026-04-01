import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/models/company_payment.dart';
import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';

/// Another payment already uses this [referenceNumber] (non-cash only).
final class DuplicateCompanyPaymentReferenceException implements Exception {
  DuplicateCompanyPaymentReferenceException(this.referenceNumber);

  final String referenceNumber;

  @override
  String toString() => 'DuplicateCompanyPaymentReferenceException($referenceNumber)';
}

/// Admin ledger: manual cash/bank/check entries in `company_payments`.
abstract final class CompanyPaymentsService {
  CompanyPaymentsService._();

  static CollectionReference<Map<String, dynamic>> collection(
    FirebaseFirestore db,
  ) =>
      db.collection(CompanyPaymentFields.collection);

  /// Newest manual payments first (requires `createdAt` on every document).
  static Query<Map<String, dynamic>> paymentsQuery(FirebaseFirestore db) {
    return collection(db).orderBy(
      CompanyPaymentFields.createdAt,
      descending: true,
    );
  }

  static Query<Map<String, dynamic>> recentPaidAuctionRequestsForPicker(
    FirebaseFirestore db, {
    int limit = 80,
  }) {
    return db
        .collection(AuctionFirestorePaths.auctionRequests)
        .where('auctionFeeStatus', isEqualTo: 'paid')
        .orderBy('auctionFeePaidAt', descending: true)
        .limit(limit);
  }

  static Query<Map<String, dynamic>> recentSoldDealsForPicker(
    FirebaseFirestore db, {
    int limit = 80,
  }) {
    return db
        .collection('deals')
        .where('status', isEqualTo: 'sold')
        .orderBy('createdAt', descending: true)
        .limit(limit);
  }

  /// Validates linkage + reference rules before write (mirrors Firestore rules intent).
  static String? validateBeforeWrite({
    required String status,
    required String source,
    required String? referenceNumber,
    required String type,
    required String relatedType,
    required String? relatedId,
  }) {
    if (!CompanyPaymentStatus.values.contains(status)) {
      return 'invalid_status';
    }
    final needsRef = source == CompanyPaymentSource.bankTransfer ||
        source == CompanyPaymentSource.certifiedCheck;
    final ref = referenceNumber?.trim() ?? '';
    if (needsRef && ref.isEmpty) {
      return 'reference_required';
    }
    if (type == CompanyPaymentType.auctionFee) {
      if (relatedType != CompanyPaymentRelatedType.auctionRequest) {
        return 'auction_fee_requires_auction_request';
      }
      if (relatedId == null || relatedId.isEmpty) {
        return 'auction_fee_requires_related_id';
      }
    } else if (type == CompanyPaymentType.commission) {
      if (relatedType != CompanyPaymentRelatedType.deal) {
        return 'commission_requires_deal';
      }
      if (relatedId == null || relatedId.isEmpty) {
        return 'commission_requires_related_id';
      }
    } else if (type == CompanyPaymentType.other) {
      if (relatedType != CompanyPaymentRelatedType.manual) {
        return 'other_requires_manual_related_type';
      }
    }
    return null;
  }

  /// Firestore document ID for bank/check payments (= [referenceNumber]).
  /// Rejects `/`, empty, and oversized IDs.
  static void assertValidReferenceDocumentId(String id) {
    final t = id.trim();
    if (t.isEmpty) {
      throw ArgumentError('reference_document_id_empty');
    }
    if (t.contains('/')) {
      throw ArgumentError('reference_document_id_contains_slash');
    }
    if (t == '.' || t == '..') {
      throw ArgumentError('reference_document_id_invalid');
    }
    if (t.length > 512) {
      throw ArgumentError('reference_document_id_too_long');
    }
  }

  static Future<void> addPayment({
    required FirebaseFirestore db,
    required double amount,
    required String status,
    required String type,
    required String reason,
    required String source,
    required String relatedType,
    String? relatedId,
    required String notes,
    String? referenceNumber,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Not signed in');

    final refTrimmed = (referenceNumber ?? '').trim();

    final err = validateBeforeWrite(
      status: status,
      source: source,
      referenceNumber:
          source == CompanyPaymentSource.cash ? null : refTrimmed,
      type: type,
      relatedType: relatedType,
      relatedId: relatedId,
    );
    if (err != null) throw ArgumentError(err);

    if (amount <= 0) throw ArgumentError('amount_must_be_positive');

    final data = <String, dynamic>{
      CompanyPaymentFields.amount: amount,
      CompanyPaymentFields.status: status,
      CompanyPaymentFields.type: type,
      CompanyPaymentFields.reason: reason,
      CompanyPaymentFields.source: source,
      CompanyPaymentFields.relatedType: relatedType,
      CompanyPaymentFields.notes: notes,
      CompanyPaymentFields.createdAt: FieldValue.serverTimestamp(),
      CompanyPaymentFields.createdBy: uid,
      CompanyPaymentFields.updatedBy: uid,
    };
    if (relatedId != null && relatedId.isNotEmpty) {
      data[CompanyPaymentFields.relatedId] = relatedId;
    }

    final col = collection(db);

    if (source == CompanyPaymentSource.bankTransfer ||
        source == CompanyPaymentSource.certifiedCheck) {
      assertValidReferenceDocumentId(refTrimmed);
      data[CompanyPaymentFields.referenceNumber] = refTrimmed;

      await db.runTransaction((transaction) async {
        final docRef = col.doc(refTrimmed);
        final snap = await transaction.get(docRef);
        if (snap.exists) {
          throw DuplicateCompanyPaymentReferenceException(refTrimmed);
        }
        transaction.set(docRef, data);
      });
    } else {
      final payRef = col.doc();
      await payRef.set(data);
    }
  }

  /// Updates allowed fields on a payment ([status], [notes]) per Firestore rules.
  /// Sets [CompanyPaymentFields.updatedBy] to the current user. Audit logs are written
  /// by Cloud Functions (`payment_logs`).
  static Future<void> updateCompanyPayment({
    required FirebaseFirestore db,
    required String paymentId,
    String? newStatus,
    String? newNotes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Not signed in');

    final payRef = collection(db).doc(paymentId);
    final snap = await payRef.get();
    if (!snap.exists) throw StateError('payment_not_found');

    final m = snap.data()!;
    final oldStatus = m[CompanyPaymentFields.status] as String? ?? '';
    final oldNotes = m[CompanyPaymentFields.notes] as String? ?? '';

    final updates = <String, dynamic>{};
    if (newStatus != null && newStatus != oldStatus) {
      if (!CompanyPaymentStatus.values.contains(newStatus)) {
        throw ArgumentError('invalid_status');
      }
      updates[CompanyPaymentFields.status] = newStatus;
    }
    if (newNotes != null && newNotes != oldNotes) {
      updates[CompanyPaymentFields.notes] = newNotes;
    }
    if (updates.isEmpty) return;

    updates[CompanyPaymentFields.updatedBy] = uid;
    await payRef.update(updates);
  }

  static double _amount(Map<String, dynamic> m) {
    final v = m[CompanyPaymentFields.amount];
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? 0;
  }

  /// Sums from payment documents. Only [CompanyPaymentStatus.confirmed] rows
  /// count (pending/rejected and legacy docs without `status` are excluded).
  static CashLedgerTotals totalsFromPaymentDocs(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    var total = 0.0;
    var sales = 0.0;
    var rent = 0.0;
    var auctions = 0.0;
    var otherReason = 0.0;
    for (final d in docs) {
      final m = d.data();
      if (m[CompanyPaymentFields.status] != CompanyPaymentStatus.confirmed) {
        continue;
      }
      final a = _amount(m);
      total += a;
      switch (m[CompanyPaymentFields.reason] as String?) {
        case CompanyPaymentReason.sale:
          sales += a;
          break;
        case CompanyPaymentReason.rent:
          rent += a;
          break;
        case CompanyPaymentReason.auction:
          auctions += a;
          break;
        default:
          otherReason += a;
      }
    }
    return CashLedgerTotals(
      totalCashIn: total,
      bySale: sales,
      byRent: rent,
      byAuction: auctions,
      byOtherReason: otherReason,
    );
  }
}

class CashLedgerTotals {
  const CashLedgerTotals({
    required this.totalCashIn,
    required this.bySale,
    required this.byRent,
    required this.byAuction,
    required this.byOtherReason,
  });

  final double totalCashIn;
  final double bySale;
  final double byRent;
  final double byAuction;
  final double byOtherReason;
}
