import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';
import 'package:aqarai_app/models/auction/lot_permission.dart';

/// [LotPermission] rows: eligibility ([canBid]) vs live session ([isActive]).
abstract final class PermissionService {
  PermissionService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AuctionFirestorePaths.lotPermissions);

  static DocumentReference<Map<String, dynamic>> ref(String permissionId) =>
      _col.doc(permissionId);

  static Stream<LotPermission?> watchPermission({
    required String userId,
    required String lotId,
  }) {
    final id = LotPermission.documentId(userId, lotId);
    return ref(id).snapshots().map((s) {
      if (!s.exists || s.data() == null) return null;
      return LotPermission.fromFirestore(s.id, s.data()!);
    });
  }

  /// Create or merge permission (admin). [canBid] reflects legal/KYC approval for this lot.
  static Future<void> upsertPermission(LotPermission permission) async {
    await ref(permission.id).set(permission.toFirestore(), SetOptions(merge: true));
  }

  /// Grants [canBid] without opening live bidding ([isActive] false until lot starts).
  static Future<void> grantCanBid({
    required String userId,
    required String lotId,
    required String auctionId,
  }) async {
    final now = DateTime.now();
    final p = LotPermission(
      id: LotPermission.documentId(userId, lotId),
      userId: userId,
      lotId: lotId,
      auctionId: auctionId,
      canBid: true,
      isActive: false,
      createdAt: now,
      updatedAt: now,
    );
    await upsertPermission(p);
  }

  /// Sets [isActive] for the given bidders on this lot (typically when lot goes live).
  static Future<void> setActiveForLot({
    required String lotId,
    required String auctionId,
    required List<String> eligibleUserIds,
    required bool isActive,
  }) async {
    final batch = _db.batch();
    final now = FieldValue.serverTimestamp();
    for (final uid in eligibleUserIds) {
      final docId = LotPermission.documentId(uid, lotId);
      batch.set(
        _col.doc(docId),
        {
          'userId': uid,
          'lotId': lotId,
          'auctionId': auctionId,
          'canBid': true,
          'isActive': isActive,
          'updatedAt': now,
        },
        SetOptions(merge: true),
      );
    }
    await batch.commit();
  }

  /// After lot ends: no user remains in “live” bidding for this lot.
  static Future<void> deactivateAllPermissionsForLot(String lotId) async {
    final snap = await _col.where('lotId', isEqualTo: lotId).get();
    if (snap.docs.isEmpty) return;
    final batch = _db.batch();
    for (final d in snap.docs) {
      batch.update(d.reference, {
        'isActive': false,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  static Future<void> revokeCanBid({
    required String userId,
    required String lotId,
  }) async {
    await ref(LotPermission.documentId(userId, lotId)).update({
      'canBid': false,
      'isActive': false,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static Stream<List<LotPermission>> watchPermissionsForLot(String lotId) {
    return _col
        .where('lotId', isEqualTo: lotId)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => LotPermission.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  /// Pause/resume live bidding for everyone who still has [canBid] on this lot.
  static Future<void> setIsActiveForCanBidOnLot({
    required String lotId,
    required bool isActive,
  }) async {
    final snap = await _col.where('lotId', isEqualTo: lotId).get();
    if (snap.docs.isEmpty) return;
    final batch = _db.batch();
    for (final d in snap.docs) {
      final data = d.data();
      if (data['canBid'] == true) {
        batch.update(d.reference, {
          'isActive': isActive,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }
    await batch.commit();
  }

  /// Re-enable bidding; [isActive] should match whether the lot session is live.
  static Future<void> enableBidderOnLot({
    required String userId,
    required String lotId,
    required String auctionId,
    required bool isActive,
  }) async {
    await ref(LotPermission.documentId(userId, lotId)).set(
      {
        'userId': userId,
        'lotId': lotId,
        'auctionId': auctionId,
        'canBid': true,
        'isActive': isActive,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  static Future<void> deletePermissionDocument({
    required String userId,
    required String lotId,
  }) async {
    await ref(LotPermission.documentId(userId, lotId)).delete();
  }
}
