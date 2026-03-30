import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/system_alert.dart';

/// Admin-only: `system_alerts` (documents created by [evaluateSystemAlerts]).
abstract final class SystemAlertsService {
  SystemAlertsService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static const String _collection = 'system_alerts';

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
}
