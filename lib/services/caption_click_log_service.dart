import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// User-side opens attributed to a caption variant → [caption_clicks].
abstract final class CaptionClickLogService {
  CaptionClickLogService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<void> logClick({
    required String captionId,
    required String propertyId,
    required String area,
  }) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final cap = captionId.trim().toUpperCase();
      if (cap.isEmpty || propertyId.trim().isEmpty) return;
      final data = <String, dynamic>{
        'captionId': cap,
        'area': area,
        'propertyId': propertyId.trim(),
        'clickedAt': FieldValue.serverTimestamp(),
      };
      if (uid != null && uid.isNotEmpty) {
        data['userId'] = uid;
      }
      await _db.collection('caption_clicks').add(data);
    } catch (e, st) {
      debugPrint('Error in CaptionClickLogService.logClick: $e\n$st');
    }
  }
}
