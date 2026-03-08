// lib/services/user_interest_service.dart
//
// Tracks buyer interests when users search via the AI assistant.
// Writes to Firestore collection "buyer_interests". Same user + same area
// updates the existing document's createdAt instead of creating a new one.

import 'package:cloud_firestore/cloud_firestore.dart';

const String _collection = 'buyer_interests';
const String _source = 'ai_chat';

class UserInterestService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Saves or updates a user's property interest from AI chat search filters.
  ///
  /// If the same user has already an interest for the same area (same areaCode),
  /// the existing document is updated (createdAt refreshed). Otherwise a new
  /// document is created.
  Future<void> saveInterest({
    required String userId,
    required Map<String, dynamic> filters,
  }) async {
    final areaCode = filters['areaCode']?.toString().trim();
    final type = filters['type']?.toString().trim();
    final serviceType = filters['serviceType']?.toString().trim();
    num? budget;
    if (filters['budget'] != null) {
      if (filters['budget'] is num) {
        budget = filters['budget'] as num;
      } else {
        budget = num.tryParse(filters['budget'].toString());
      }
    }

    final docId = _docIdForUserAndArea(userId, areaCode);

    await _firestore.collection(_collection).doc(docId).set({
      'userId': userId,
      'areaCode': areaCode,
      'type': type,
      'serviceType': serviceType,
      'budget': budget,
      'createdAt': FieldValue.serverTimestamp(),
      'source': _source,
    }, SetOptions(merge: true));
  }

  /// Deterministic document ID so the same user + same area updates one document.
  String _docIdForUserAndArea(String userId, String? areaCode) {
    final a = areaCode ?? 'no_area';
    return '${userId}_${a}';
  }
}
