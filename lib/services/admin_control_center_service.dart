import 'package:cloud_firestore/cloud_firestore.dart';

/// Firestore streams and admin writes for the marketing control center.
abstract final class AdminControlCenterService {
  AdminControlCenterService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const String _learning = 'auto_decision_learning';
  static const String _stateDoc = 'state';
  static const String _notificationLogs = 'notification_logs';

  static Stream<DocumentSnapshot<Map<String, dynamic>>> watchLearningState() =>
      _db.collection(_learning).doc(_stateDoc).snapshots();

  static Stream<QuerySnapshot<Map<String, dynamic>>>
      watchNotificationLogsForPerformance({int limit = 40}) {
    return _db
        .collection(_notificationLogs)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots();
  }

  /// Resets learned trust, counters, shield, and outcome snapshot fields on [state].
  static Future<void> resetLearningState() async {
    await _db.collection(_learning).doc(_stateDoc).set(
      <String, dynamic>{
        'captionTrust': 1.0,
        'timeTrust': 1.0,
        'audienceTrust': 1.0,
        'patternTrust': 1.0,
        'totalDecisions': 0,
        'acceptedCount': 0,
        'overrideCount': 0,
        'captionOverrideCount': 0,
        'audienceOverrideCount': 0,
        'timeOverrideCount': 0,
        'autoFailures': 0,
        'autoSuccesses': 0,
        'autoShieldEnabled': false,
        'manualRecoveryStreak': 0,
        'outcomeLearningDeltaPct': FieldValue.delete(),
        'outcomeLearningBeatExpectation': FieldValue.delete(),
        'outcomeLearningEvaluatedAt': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// Clears auto-shield so auto can run again when gates pass (local prefs unchanged).
  static Future<void> disableShieldManually() async {
    await _db.collection(_learning).doc(_stateDoc).set(
      {
        'autoShieldEnabled': false,
        'autoFailures': 0,
        'manualRecoveryStreak': 0,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
