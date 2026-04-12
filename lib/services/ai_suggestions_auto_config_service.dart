import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AiSuggestionsAutoConfig {
  const AiSuggestionsAutoConfig({
    required this.aiEnabled,
    required this.manualOverride,
    required this.suggestionVariant,
    required this.defaultPlanDays,
    required this.urgencyLevel,
    required this.exposureMultiplier,
    required this.configVersion,
    this.updatedAt,
    this.updatedBy,
    this.changeSummary,
  });

  final bool aiEnabled;
  final bool manualOverride;
  final String suggestionVariant; // "A" | "B"
  final int defaultPlanDays; // e.g. 30
  final int urgencyLevel; // 1..n
  final double exposureMultiplier; // 0.5..2.0
  final int configVersion;

  /// Last config write time (server).
  final DateTime? updatedAt;
  final String? updatedBy;
  final String? changeSummary;

  /// Written by [autoTuneAiSuggestionsConfig] — must match Cloud Function.
  static const String updatedBySystemAutoTune = 'system:auto_tune';

  static const AiSuggestionsAutoConfig defaults = AiSuggestionsAutoConfig(
    aiEnabled: true,
    manualOverride: false,
    suggestionVariant: 'A',
    defaultPlanDays: 30,
    urgencyLevel: 1,
    exposureMultiplier: 1.0,
    configVersion: 0,
    updatedAt: null,
    updatedBy: null,
    changeSummary: null,
  );

  static AiSuggestionsAutoConfig fromMap(Map<String, dynamic>? m) {
    if (m == null) return defaults;

    final aiEnabled = m['aiEnabled'] != false;
    final manualOverride = m['manualOverride'] == true;

    final v = (m['suggestionVariant'] ?? 'A').toString().trim();
    final variant = (v == 'B') ? 'B' : 'A';

    final dp = m['defaultPlanDays'];
    final defaultPlanDays = dp is num ? dp.toInt() : 30;

    final ul = m['urgencyLevel'];
    final urgencyLevel = ul is num ? ul.toInt() : 1;

    final em = m['exposureMultiplier'];
    final rawExposure = em is num ? em.toDouble() : 1.0;
    final exposureMultiplier = rawExposure.clamp(0.5, 2.0);

    final cv = m['configVersion'];
    final configVersion = cv is num ? cv.toInt() : 0;

    final ua = m['updatedAt'];
    final updatedAt = ua is Timestamp ? ua.toDate() : null;

    final ub = m['updatedBy'];
    final updatedBy = ub == null
        ? null
        : ub.toString().trim().isEmpty
            ? null
            : ub.toString().trim();

    final cs = m['changeSummary'];
    final changeSummary = cs == null
        ? null
        : cs.toString().trim().isEmpty
            ? null
            : cs.toString().trim();

    return AiSuggestionsAutoConfig(
      aiEnabled: aiEnabled,
      manualOverride: manualOverride,
      suggestionVariant: variant,
      defaultPlanDays: defaultPlanDays <= 0 ? 30 : defaultPlanDays,
      urgencyLevel: urgencyLevel <= 0 ? 1 : urgencyLevel,
      exposureMultiplier: exposureMultiplier <= 0 ? 1.0 : exposureMultiplier,
      configVersion: configVersion,
      updatedAt: updatedAt,
      updatedBy: updatedBy,
      changeSummary: changeSummary,
    );
  }
}

abstract final class AiSuggestionsAutoConfigService {
  AiSuggestionsAutoConfigService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static DocumentReference<Map<String, dynamic>> get _ref =>
      _db.collection('analytics').doc('ai_suggestions_config');

  static Stream<AiSuggestionsAutoConfig> watch() {
    return _ref.snapshots().map((s) => AiSuggestionsAutoConfig.fromMap(s.data()));
  }

  static CollectionReference<Map<String, dynamic>> get _history =>
      _db.collection('ai_config_history');

  /// Newest history first (requires `createdAt` on each entry).
  static Query<Map<String, dynamic>> historyQuery({int limit = 10}) {
    return _history
        .orderBy('createdAt', descending: true)
        .limit(limit);
  }

  /// Admin UI — merge partial updates into [analytics/ai_suggestions_config],
  /// increment [configVersion], append [ai_config_history].
  static Future<void> patchConfig({
    bool? aiEnabled,
    bool? manualOverride,
    double? exposureMultiplier,
    int? defaultPlanDays,
    String? changeSummary,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim();
    final updatedBy = (uid == null || uid.isEmpty) ? 'unknown' : uid;

    final parts = <String>[];
    if (aiEnabled != null) parts.add('aiEnabled=$aiEnabled');
    if (manualOverride != null) {
      parts.add('manualOverride=$manualOverride');
    }
    if (exposureMultiplier != null) {
      parts.add(
        'exposureMultiplier=${exposureMultiplier.clamp(0.5, 2.0).toStringAsFixed(2)}',
      );
    }
    if (defaultPlanDays != null) {
      parts.add('defaultPlanDays=$defaultPlanDays');
    }
    final summary = (changeSummary != null && changeSummary.trim().isNotEmpty)
        ? changeSummary.trim()
        : (parts.isEmpty ? 'config_update' : parts.join('; '));

    await _db.runTransaction((tx) async {
      final snap = await tx.get(_ref);
      final cur = Map<String, dynamic>.from(snap.data() ?? {});

      final prevV = (cur['configVersion'] is num)
          ? (cur['configVersion'] as num).toInt()
          : 0;
      final nextV = prevV + 1;

      var ai = cur['aiEnabled'] != false;
      if (aiEnabled != null) ai = aiEnabled;

      var mo = cur['manualOverride'] == true;
      if (manualOverride != null) mo = manualOverride;

      var exp = 1.0;
      final emCur = cur['exposureMultiplier'];
      if (emCur is num) {
        exp = emCur.toDouble().clamp(0.5, 2.0);
      }
      final emPatch = exposureMultiplier;
      if (emPatch != null) {
        exp = emPatch.clamp(0.5, 2.0);
      }

      var plan = 30;
      final dpCur = cur['defaultPlanDays'];
      if (dpCur is num) plan = dpCur.toInt();
      if (defaultPlanDays != null) {
        final d = defaultPlanDays;
        plan = kDefaultPlanOptionsSet.contains(d) ? d : 30;
      }
      if (!kDefaultPlanOptionsSet.contains(plan)) plan = 30;

      var variant = (cur['suggestionVariant'] ?? 'A').toString().trim();
      if (variant != 'B') variant = 'A';

      var ul = 1;
      final ulCur = cur['urgencyLevel'];
      if (ulCur is num) ul = ulCur.toInt();
      if (ul <= 0) ul = 1;

      tx.set(_ref, {
        'kind': 'ai_suggestions_config',
        'aiEnabled': ai,
        'manualOverride': mo,
        'defaultPlanDays': plan,
        'exposureMultiplier': exp,
        'configVersion': nextV,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': updatedBy,
        'changeSummary': summary,
      }, SetOptions(merge: true));

      final snapshot = Map<String, dynamic>.from(cur);
      snapshot.addAll(<String, dynamic>{
        'kind': 'ai_suggestions_config',
        'aiEnabled': ai,
        'manualOverride': mo,
        'suggestionVariant': variant,
        'defaultPlanDays': plan,
        'urgencyLevel': ul,
        'exposureMultiplier': exp,
        'configVersion': nextV,
        'updatedBy': updatedBy,
        'changeSummary': summary,
      });

      final histRef = _history.doc();
      tx.set(histRef, {
        'configVersion': nextV,
        'updatedBy': updatedBy,
        'changeSummary': summary,
        'snapshot': snapshot,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Restores [analytics/ai_suggestions_config] from a history entry's [snapshot],
  /// increments [configVersion], and appends a new [ai_config_history] row.
  static Future<void> restoreConfigFromHistory({
    required String historyDocId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid.trim();
    final updatedBy = (uid == null || uid.isEmpty) ? 'unknown' : uid;

    await _db.runTransaction((tx) async {
      final histRef = _history.doc(historyDocId);
      final histSnap = await tx.get(histRef);
      if (!histSnap.exists) {
        throw StateError('ai_config_history entry not found: $historyDocId');
      }
      final histData = histSnap.data() ?? {};
      final rawSnap = histData['snapshot'];
      if (rawSnap is! Map) {
        throw StateError('History entry has no snapshot map');
      }
      final fromVersion = (histData['configVersion'] is num)
          ? (histData['configVersion'] as num).toInt()
          : (rawSnap['configVersion'] is num)
              ? (rawSnap['configVersion'] as num).toInt()
              : 0;

      final snapshot = _cloneFirestoreMap(Map<String, dynamic>.from(
        rawSnap.map((k, v) => MapEntry(k.toString(), v)),
      ));

      final cfgSnap = await tx.get(_ref);
      final cur = cfgSnap.data() ?? {};
      final prevV =
          (cur['configVersion'] is num) ? (cur['configVersion'] as num).toInt() : 0;
      final nextV = prevV + 1;
      final summary = 'Restored from version $fromVersion';

      tx.set(_ref, {
        ...snapshot,
        'kind': 'ai_suggestions_config',
        'configVersion': nextV,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': updatedBy,
        'changeSummary': summary,
      }, SetOptions(merge: true));

      final snapForHist = Map<String, dynamic>.from(snapshot);
      snapForHist['kind'] = 'ai_suggestions_config';
      snapForHist['configVersion'] = nextV;
      snapForHist['updatedBy'] = updatedBy;
      snapForHist['changeSummary'] = summary;

      tx.set(_history.doc(), {
        'configVersion': nextV,
        'updatedBy': updatedBy,
        'changeSummary': summary,
        'snapshot': snapForHist,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  static Map<String, dynamic> _cloneFirestoreMap(Map<String, dynamic> m) {
    return m.map((k, v) {
      if (v is Map) {
        return MapEntry(
          k,
          _cloneFirestoreMap(Map<String, dynamic>.from(
            v.map((k2, v2) => MapEntry(k2.toString(), v2)),
          )),
        );
      }
      if (v is List) {
        return MapEntry(
          k,
          v.map((e) {
            if (e is Map) {
              return _cloneFirestoreMap(Map<String, dynamic>.from(
                e.map((k2, v2) => MapEntry(k2.toString(), v2)),
              ));
            }
            return e;
          }).toList(),
        );
      }
      return MapEntry(k, v);
    });
  }

  static const Set<int> kDefaultPlanOptionsSet = {3, 7, 14, 30};
}

