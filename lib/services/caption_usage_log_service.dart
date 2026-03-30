import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/utils/caption_factor_analyzer.dart';

/// Admin “caption used” events → [caption_usage_logs].
abstract final class CaptionUsageLogService {
  CaptionUsageLogService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<void> logUsage({
    required String captionId,
    required String captionText,
    required String area,
    required String propertyType,
    required String demandLevel,
    required int dealsCount,
  }) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final id = captionId.trim().toUpperCase();
      if (id.isEmpty) return;
      final factors = CaptionFactorAnalyzer.factorsMap(captionText, area);
      await _db.collection('caption_usage_logs').add({
        'captionId': id,
        'captionText': captionText,
        'area': area,
        'propertyType': propertyType,
        'demandLevel': demandLevel,
        'dealsCount': dealsCount,
        'factors': factors,
        'createdAt': FieldValue.serverTimestamp(),
        'adminUid': uid,
      });
    } catch (_) {}
  }
}
