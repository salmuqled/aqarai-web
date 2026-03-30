import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/models/auto_decision.dart';
import 'package:aqarai_app/models/auto_decision_trust.dart';
import 'package:aqarai_app/models/auto_marketing_gate_state.dart';
import 'package:aqarai_app/models/decision_accuracy_snapshot.dart';

/// Logs smart marketing decisions to [auto_decision_logs] and updates
/// [auto_decision_learning/state] (per-dimension trust + aggregates). Never throws.
abstract final class DecisionTrackingService {
  DecisionTrackingService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const String _logs = 'auto_decision_logs';
  static const String _learning = 'auto_decision_learning';
  static const String _stateDoc = 'state';

  static final RegExp _cidRegex = RegExp(
    r'[?&]cid=([ABCabc])',
    caseSensitive: false,
  );

  /// Legacy: average of dimension trusts, or [patternTrust] if only that exists.
  static Future<double> getPatternTrustMultiplier() async {
    final t = await getDimensionTrust();
    return t.patternTrustCompatible.clamp(0.5, 1.0);
  }

  static Future<AutoMarketingGateState> getAutoMarketingGateState() async {
    try {
      final snap = await _db.collection(_learning).doc(_stateDoc).get();
      return AutoMarketingGateState.fromStateMap(snap.data());
    } catch (_) {
      return AutoMarketingGateState.fallback;
    }
  }

  static Future<AutoDecisionTrust> getDimensionTrust() async {
    final g = await getAutoMarketingGateState();
    return g.trust;
  }

  static Stream<DecisionAccuracySnapshot> watchDecisionAccuracy() {
    return _db.collection(_learning).doc(_stateDoc).snapshots().map(
          (s) => DecisionAccuracySnapshot.fromStateMap(s.data()),
        );
  }

  /// Prefer `cid=` in URL; else [fallbackId] (usually suggested variant).
  static String inferCaptionIdFromBody(String body, String fallbackId) {
    final m = _cidRegex.firstMatch(body);
    if (m != null) return m.group(1)!.toUpperCase();
    final t = fallbackId.trim().toUpperCase();
    if (t == 'A' || t == 'B' || t == 'C') return t;
    return t.isNotEmpty ? t : 'A';
  }

  static bool _normAudienceEq(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  static bool _hourEq(int a, int b) => (a % 24) == (b % 24);

  static String? _overrideReason({
    required bool captionChanged,
    required bool timeChanged,
    required bool audienceChanged,
  }) {
    if (captionChanged && !timeChanged && !audienceChanged) {
      return 'caption_bad';
    }
    if (timeChanged && !captionChanged && !audienceChanged) {
      return 'time_bad';
    }
    if (audienceChanged && !captionChanged && !timeChanged) {
      return 'audience_wrong';
    }
    if (captionChanged) return 'caption_bad';
    if (timeChanged) return 'time_bad';
    if (audienceChanged) return 'audience_wrong';
    return null;
  }

  static int _intFromPrev(Map<String, dynamic> prev, String key) {
    final v = prev[key];
    if (v is int) return v;
    if (v is num) return v.round();
    return 0;
  }

  /// Returns Firestore doc id for [autoDecisionLogId] payload to Cloud Functions.
  static Future<String?> logDecisionAndReturnId({
    required AutoDecision decision,
    required String chosenCaptionId,
    required String chosenAudience,
    required int chosenTime,
    required bool override,
    required String decisionLevel,
    bool autoExecuted = false,
    String? chosenBodyForDiff,
  }) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final suggestedCaption = decision.captionId.toUpperCase();
      final chosenCap = chosenCaptionId.trim().toUpperCase();
      final suggestedAud = decision.audienceSegment;
      final chosenAud = chosenAudience.trim().isEmpty
          ? suggestedAud
          : chosenAudience.trim();

      final captionChanged = override &&
          (chosenCap != suggestedCaption ||
              (chosenBodyForDiff != null &&
                  chosenBodyForDiff.trim() !=
                      decision.notificationBody.trim()));
      final audienceChanged =
          override && !_normAudienceEq(chosenAud, suggestedAud);
      final timeChanged =
          override && !_hourEq(chosenTime, decision.bestHour);

      final overrideReason = override
          ? _overrideReason(
              captionChanged: captionChanged,
              timeChanged: timeChanged,
              audienceChanged: audienceChanged,
            )
          : null;

      final logRef = _db.collection(_logs).doc();
      final logId = logRef.id;
      final stateRef = _db.collection(_learning).doc(_stateDoc);

      await _db.runTransaction((tx) async {
        final stateSnap = await tx.get(stateRef);
        final prev = stateSnap.data() ?? <String, dynamic>{};

        final totalBefore = _intFromPrev(prev, 'totalDecisions');
        final rateMult = totalBefore < 50 ? 2.0 : 1.0;

        final base = AutoDecisionTrust.fromStateMap(prev);
        var c = base.captionTrust;
        var t = base.timeTrust;
        var a = base.audienceTrust;

        if (!override) {
          final d = 0.01 * rateMult;
          c = (c + d).clamp(0.5, 1.0);
          t = (t + d).clamp(0.5, 1.0);
          a = (a + d).clamp(0.5, 1.0);
        } else {
          final d = 0.02 * rateMult;
          if (captionChanged) c = (c - d).clamp(0.5, 1.0);
          if (timeChanged) t = (t - d).clamp(0.5, 1.0);
          if (audienceChanged) a = (a - d).clamp(0.5, 1.0);
        }

        final patternTrust = ((c + t + a) / 3.0).clamp(0.5, 1.0);

        final logData = <String, dynamic>{
          'decisionId': logId,
          'suggestedCaptionId': suggestedCaption,
          'chosenCaptionId': chosenCap,
          'override': override,
          'suggestedAudience': suggestedAud,
          'chosenAudience': chosenAud,
          'suggestedTime': decision.bestHour,
          'chosenTime': chosenTime % 24,
          'confidence': decision.confidence,
          'expectedCtr': decision.expectedCtr,
          'createdAt': FieldValue.serverTimestamp(),
          'adminUid': uid,
          'evaluated': false,
          'outcomeCtrApplied': false,
          'decisionLevel': decisionLevel,
          'autoExecuted': autoExecuted,
          if (override) ...{
            'captionChanged': captionChanged,
            'audienceChanged': audienceChanged,
            'timeChanged': timeChanged,
            if (overrideReason != null) 'overrideReason': overrideReason,
          },
        };
        tx.set(logRef, logData);

        final updates = <String, dynamic>{
          'captionTrust': c,
          'timeTrust': t,
          'audienceTrust': a,
          'patternTrust': patternTrust,
          'totalDecisions': FieldValue.increment(1),
          'acceptedCount': FieldValue.increment(override ? 0 : 1),
          'overrideCount': FieldValue.increment(override ? 1 : 0),
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (override) {
          if (captionChanged) {
            updates['captionOverrideCount'] = FieldValue.increment(1);
          }
          if (audienceChanged) {
            updates['audienceOverrideCount'] = FieldValue.increment(1);
          }
          if (timeChanged) {
            updates['timeOverrideCount'] = FieldValue.increment(1);
          }
        }
        tx.set(stateRef, updates, SetOptions(merge: true));
      });
      return logId;
    } catch (_) {
      return null;
    }
  }

  static Future<void> markAutoExecuted(String logId) async {
    try {
      await _db.collection(_logs).doc(logId).update({'autoExecuted': true});
    } catch (_) {}
  }

  /// Fire-and-forget safe: swallow all errors.
  static void logDecision({
    required AutoDecision decision,
    required String chosenCaptionId,
    required String chosenAudience,
    required int chosenTime,
    required bool override,
    required String decisionLevel,
    String? chosenBodyForDiff,
  }) {
    unawaited(
      logDecisionAndReturnId(
        decision: decision,
        chosenCaptionId: chosenCaptionId,
        chosenAudience: chosenAudience,
        chosenTime: chosenTime,
        override: override,
        decisionLevel: decisionLevel,
        chosenBodyForDiff: chosenBodyForDiff,
      ),
    );
  }
}
