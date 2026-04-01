import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:aqarai_app/config/auction_listing_fee.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';

/// Submits and reads `auction_requests` (user → admin review).
abstract final class AuctionRequestService {
  AuctionRequestService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AuctionFirestorePaths.auctionRequests);

  /// Signed-in non-anonymous users only. Optional main photo like [AddPropertyPage].
  static Future<String> submitRequest({
    required String propertyType,
    required String governorateAr,
    required String governorateEn,
    required String areaAr,
    required String areaEn,
    required String governorateCode,
    required String areaCode,
    required double price,
    required double size,
    required int roomCount,
    required int masterRoomCount,
    required int bathroomCount,
    required int parkingCount,
    required bool hasElevator,
    required bool hasCentralAC,
    required bool hasSplitAC,
    required bool hasMaidRoom,
    required bool hasDriverRoom,
    required bool hasLaundryRoom,
    required bool hasGarden,
    required String description,
    required bool acceptLowerStartPrice,
    File? imageFile,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.isAnonymous) {
      throw StateError('Signed-in account required');
    }
    final uid = user.uid;

    final docRef = _col.doc();
    final id = docRef.id;

    final urls = <String>[];
    if (imageFile != null) {
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('auction_request_images/$uid/$id/0.jpg');
      await storageRef.putFile(imageFile);
      urls.add(await storageRef.getDownloadURL());
    }

    final governorateDisplay =
        governorateAr.isNotEmpty ? governorateAr : governorateEn;
    final areaDisplay = areaAr.isNotEmpty ? areaAr : areaEn;

    await docRef.set(<String, dynamic>{
      'userId': uid,
      'propertyType': propertyType,
      'governorate': governorateDisplay,
      'area': areaDisplay,
      'governorateAr': governorateAr,
      'governorateEn': governorateEn,
      'areaAr': areaAr,
      'areaEn': areaEn,
      'governorateCode': governorateCode,
      'areaCode': areaCode,
      'price': price,
      'size': size,
      'roomCount': roomCount,
      'masterRoomCount': masterRoomCount,
      'bathroomCount': bathroomCount,
      'parkingCount': parkingCount,
      'hasElevator': hasElevator,
      'hasCentralAC': hasCentralAC,
      'hasSplitAC': hasSplitAC,
      'hasMaidRoom': hasMaidRoom,
      'hasDriverRoom': hasDriverRoom,
      'hasLaundryRoom': hasLaundryRoom,
      'hasGarden': hasGarden,
      'description': description.trim(),
      'images': urls,
      'acceptLowerStartPrice': acceptLowerStartPrice,
      'status': AuctionRequestStatus.pending.firestoreValue,
      'createdAt': FieldValue.serverTimestamp(),
      'auctionFee': AuctionListingFees.defaultKwd,
      'auctionFeeStatus': 'pending',
    });

    return id;
  }

  static Stream<DocumentSnapshot<Map<String, dynamic>>> streamRequest(
    String requestId,
  ) {
    return _col.doc(requestId).snapshots();
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> watchAllRequests() {
    return _col.orderBy('createdAt', descending: true).snapshots();
  }

  static Future<void> updateStatus({
    required String requestId,
    required AuctionRequestStatus status,
  }) async {
    await _col.doc(requestId).update({
      'status': status.firestoreValue,
      'reviewedAt': FieldValue.serverTimestamp(),
    });
  }
}
