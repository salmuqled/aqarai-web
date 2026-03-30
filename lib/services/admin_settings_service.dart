import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/hybrid_marketing_settings.dart';

/// Global admin configuration document: `admin_settings/global`.
abstract final class AdminSettingsService {
  AdminSettingsService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const String collection = 'admin_settings';
  static const String globalDocId = 'global';

  static const String _hybridAutoExec = 'hybridAutoExecutionEnabled';
  static const String _hybridAutoTh = 'hybridAutoThreshold';
  static const String _hybridReviewTh = 'hybridReviewThreshold';

  /// Real-time hybrid marketing settings (defaults if doc missing).
  static Stream<HybridMarketingSettings> watchSettings() {
    return _db.collection(collection).doc(globalDocId).snapshots().map(
          (snap) => HybridMarketingSettings.fromFirestoreMap(snap.data()),
        );
  }

  /// Persists hybrid fields with merge. Requires admin Firestore rules.
  static Future<void> saveSettings(HybridMarketingSettings settings) async {
    final n = settings.copyWith();
    await _db.collection(collection).doc(globalDocId).set(
      {
        _hybridAutoExec: n.autoExecutionEnabled,
        _hybridAutoTh: n.autoThreshold,
        _hybridReviewTh: n.reviewThreshold,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
