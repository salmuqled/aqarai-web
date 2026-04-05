import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/models/listing_enums.dart';

/// Phone capture + optional `deals` row for "I'm interested" (commission protection).
abstract final class InterestLeadFlowService {
  InterestLeadFlowService._();

  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// Deterministic id: one interest deal per user per property or wanted listing.
  static String interestDealDocId({
    required String uid,
    String? propertyId,
    String? wantedId,
  }) {
    if (propertyId != null && propertyId.isNotEmpty) {
      return 'int_${uid}_$propertyId';
    }
    if (wantedId != null && wantedId.isNotEmpty) {
      return 'int_${uid}_w_$wantedId';
    }
    throw ArgumentError('propertyId or wantedId required');
  }

  /// Persists [phone] on `users/{uid}` (merge).
  static Future<void> saveUserPhone({
    required String uid,
    required String phone,
  }) async {
    final t = phone.trim();
    if (t.isEmpty) throw ArgumentError('phone empty');
    await _db.collection('users').doc(uid).set(
      {'phone': t},
      SetOptions(merge: true),
    );
  }

  /// Creates interest `deals` doc if missing. Returns `true` if newly created.
  static Future<bool> ensureInterestDeal({
    required String phone,
    required String propertyId,
    required String propertyTitle,
    required num propertyPrice,
    required String serviceTypeRaw,
    String? wantedId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('not_signed_in');

    final uid = user.uid;
    final email = user.email ?? '';

    final svc = _normalizeServiceType(serviceTypeRaw);

    final docId = interestDealDocId(
      uid: uid,
      propertyId: propertyId.isNotEmpty ? propertyId : null,
      wantedId: wantedId,
    );

    final ref = _db.collection('deals').doc(docId);

    var created = false;
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) return;

      tx.set(ref, {
        'propertyId': propertyId,
        if (wantedId != null && wantedId.isNotEmpty) 'wantedId': wantedId,
        'propertyTitle': propertyTitle,
        'propertyPrice': propertyPrice,
        'clientId': uid,
        'clientEmail': email,
        'clientPhone': phone.trim(),
        'serviceType': svc,
        'status': DealStatus.newLead,
        'dealStatus': DealStatus.newLead,
        'finalPrice': 0.0,
        'commission': 0.0,
        'commissionAmount': 0.0,
        'commissionCalculated': false,
        'bookingAmount': 0.0,
        'isBooked': false,
        'isSigned': false,
        'isCommissionPaid': false,
        'leadSource': DealLeadSource.interestedButton,
        'leadCreatedAt': FieldValue.serverTimestamp(),
        'interestSource': wantedId != null && wantedId.isNotEmpty
            ? 'wanted_detail'
            : 'property_detail',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      created = true;
    });

    return created;
  }

  static String _normalizeServiceType(String raw) {
    final t = raw.trim().toLowerCase();
    if (t == CloseRequestType.rent || t == DealType.rent) return 'rent';
    if (t == CloseRequestType.exchange || t == DealType.exchange) {
      return 'exchange';
    }
    return 'sale';
  }
}
