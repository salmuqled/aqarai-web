import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';
import 'package:aqarai_app/models/auction/auction_participant.dart';

abstract final class AuctionService {
  AuctionService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AuctionFirestorePaths.auctions);

  static CollectionReference<Map<String, dynamic>> get _participantsCol =>
      _db.collection(AuctionFirestorePaths.participants);

  static DocumentReference<Map<String, dynamic>> ref(String auctionId) =>
      _col.doc(auctionId);

  static Stream<Auction?> watchAuction(String auctionId) {
    return ref(auctionId).snapshots().map((s) {
      if (!s.exists || s.data() == null) return null;
      return Auction.fromFirestore(s.id, s.data()!);
    });
  }

  static Future<Auction?> getAuction(String auctionId) async {
    final s = await ref(auctionId).get();
    if (!s.exists || s.data() == null) return null;
    return Auction.fromFirestore(s.id, s.data()!);
  }

  /// Publishes a new auction (caller must enforce admin auth).
  static Future<String> createAuction({
    required String title,
    String description = '',
    required String ministryApprovalNumber,
    required DateTime startDate,
    required DateTime endDate,
    required String createdBy,
    AuctionStatus status = AuctionStatus.draft,
  }) async {
    final doc = _col.doc();
    final now = DateTime.now();
    final auction = Auction(
      id: doc.id,
      title: title,
      description: description,
      ministryApprovalNumber: ministryApprovalNumber,
      startDate: startDate,
      endDate: endDate,
      status: status,
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
    );
    await doc.set(auction.toFirestore());
    return doc.id;
  }

  static Future<void> updateAuctionStatus({
    required String auctionId,
    required AuctionStatus status,
  }) async {
    await ref(auctionId).update({
      'status': status.firestoreValue,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> updateAuction(
    Auction auction, {
    bool includeTimestamps = true,
  }) async {
    final map = auction.toFirestore();
    if (includeTimestamps) {
      map['updatedAt'] = FieldValue.serverTimestamp();
    }
    await ref(auction.id).update(map);
  }

  /// Next catalog auction: earliest [startDate] among upcoming / open registration.
  static Stream<Auction?> watchNextUpcomingAuction() {
    return _col
        .where('status', whereIn: [
          AuctionStatus.upcoming.firestoreValue,
          AuctionStatus.registrationOpen.firestoreValue,
        ])
        .orderBy('startDate')
        .limit(1)
        .snapshots()
        .map((s) {
          if (s.docs.isEmpty) return null;
          final d = s.docs.first;
          return Auction.fromFirestore(d.id, d.data());
        });
  }

  /// Visible auctions (excludes draft) for authenticated users.
  static Stream<List<Auction>> watchPublishedAuctions({int limit = 50}) {
    return _col
        .where('status', whereIn: [
          AuctionStatus.upcoming.firestoreValue,
          AuctionStatus.registrationOpen.firestoreValue,
          AuctionStatus.closed.firestoreValue,
          AuctionStatus.live.firestoreValue,
          AuctionStatus.finished.firestoreValue,
        ])
        .limit(limit)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => Auction.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  // --- auction_participants ---

  static Stream<AuctionParticipant?> watchParticipant({
    required String userId,
    required String auctionId,
  }) {
    final id = AuctionParticipant.documentId(userId, auctionId);
    return _participantsCol.doc(id).snapshots().map((s) {
      if (!s.exists || s.data() == null) return null;
      return AuctionParticipant.fromFirestore(s.id, s.data()!);
    });
  }

  /// Idempotent: does nothing if `auction_participants/{userId}_{auctionId}` exists.
  static Future<void> createParticipant({
    required String userId,
    required String auctionId,
  }) async {
    final id = AuctionParticipant.documentId(userId, auctionId);
    final docRef = _participantsCol.doc(id);
    final snap = await docRef.get();
    if (snap.exists) return;
    final p = AuctionParticipant(
      id: id,
      userId: userId,
      auctionId: auctionId,
      status: ParticipantStatus.pending,
      createdAt: DateTime.now(),
    );
    await docRef.set(p.toFirestore());
  }

  /// Same as [createParticipant] (legacy name).
  static Future<void> registerForAuction({
    required String userId,
    required String auctionId,
  }) =>
      createParticipant(userId: userId, auctionId: auctionId);

  /// Approved bidders for [auctionId] (for activating lot sessions).
  static Future<List<String>> approvedParticipantUserIds(String auctionId) async {
    final q = await _participantsCol
        .where('auctionId', isEqualTo: auctionId)
        .where('status', isEqualTo: ParticipantStatus.approved.firestoreValue)
        .get();
    final out = <String>[];
    for (final d in q.docs) {
      final u = d.data()['userId']?.toString();
      if (u != null && u.isNotEmpty) out.add(u);
    }
    return out;
  }

  static Stream<List<AuctionParticipant>> watchParticipantsForAuction(
    String auctionId,
  ) {
    return _participantsCol
        .where('auctionId', isEqualTo: auctionId)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => AuctionParticipant.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  static Future<void> adminSetParticipantStatus({
    required String userId,
    required String auctionId,
    required ParticipantStatus status,
    required String approvedBy,
    String? notes,
  }) async {
    final id = AuctionParticipant.documentId(userId, auctionId);
    await _participantsCol.doc(id).set(
      {
        'userId': userId,
        'auctionId': auctionId,
        'status': status.firestoreValue,
        'approvedBy': approvedBy,
        'approvedAt': FieldValue.serverTimestamp(),
        if (notes != null) 'notes': notes,
      },
      SetOptions(merge: true),
    );
  }
}
