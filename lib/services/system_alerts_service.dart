import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:aqarai_app/models/system_alert.dart';
import 'package:aqarai_app/services/upload_health_service.dart';

/// Admin-only: `system_alerts` (documents created by [evaluateSystemAlerts]).
abstract final class SystemAlertsService {
  SystemAlertsService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static const String _collection = 'system_alerts';

  static const String typeUploadIssue = 'upload_issue';

  /// Newest first by [SystemAlert.updatedAt] / [SystemAlert.createdAt] (client sort; no index required).
  static Stream<List<SystemAlert>> watchAlerts() {
    return _db.collection(_collection).snapshots().map((snap) {
      final out = <SystemAlert>[];
      for (final d in snap.docs) {
        final a = SystemAlert.fromDoc(d);
        if (a != null) out.add(a);
      }
      out.sort((a, b) {
        final ta = a.updatedAt ?? a.createdAt;
        final tb = b.updatedAt ?? b.createdAt;
        if (ta == null && tb == null) return 0;
        if (ta == null) return 1;
        if (tb == null) return -1;
        return tb.compareTo(ta);
      });
      return out;
    });
  }

  static Future<void> markAsRead(String alertId) async {
    await _db.collection(_collection).doc(alertId).update({
      'read': true,
      'readAt': FieldValue.serverTimestamp(),
    });
  }

  /// Client-emitted when upload health thresholds are exceeded (admin dashboard).
  static Future<bool> logUploadReliabilityIssue({
    required UploadHealthSnapshot snapshot,
    required String windowLabel,
  }) async {
    final metrics = snapshot.toMetricsMap(windowLabel: windowLabel);
    try {
      final now = FieldValue.serverTimestamp();
      await _db.collection(_collection).add({
        'type': typeUploadIssue,
        'severity': 'warning',
        'titleEn': 'Upload reliability',
        'titleAr': 'موثوقية رفع الصور',
        'messageEn': 'Upload reliability issue detected',
        'messageAr': 'تم رصد مشكلة في موثوقية رفع الصور',
        'read': false,
        'metrics': metrics,
        'timestamp': now,
        'createdAt': now,
        'updatedAt': now,
      });
      return true;
    } catch (e) {
      debugPrint('[SystemAlerts] logUploadReliabilityIssue failed: $e');
      return false;
    }
  }
}
