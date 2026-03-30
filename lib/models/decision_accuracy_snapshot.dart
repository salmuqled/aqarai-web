import 'package:aqarai_app/models/auto_decision_trust.dart';

/// Aggregated stats from [auto_decision_learning/state] (+ optional recent logs).
class DecisionAccuracySnapshot {
  const DecisionAccuracySnapshot({
    required this.totalDecisions,
    required this.acceptedCount,
    required this.overrideCount,
    required this.patternTrust,
    required this.captionTrust,
    required this.timeTrust,
    required this.audienceTrust,
    required this.captionOverrideCount,
    required this.audienceOverrideCount,
    required this.timeOverrideCount,
    this.outcomeLearningDeltaPct,
    this.outcomeLearningBeatExpectation,
    this.autoShieldEnabled = false,
  });

  final int totalDecisions;
  final int acceptedCount;
  final int overrideCount;
  final double patternTrust;
  final double captionTrust;
  final double timeTrust;
  final double audienceTrust;
  final int captionOverrideCount;
  final int audienceOverrideCount;
  final int timeOverrideCount;

  /// Last full outcome (24h) vs expected CTR, percentage points (actual − expected)×100.
  final double? outcomeLearningDeltaPct;

  /// Whether last evaluated outcome beat expected CTR.
  final bool? outcomeLearningBeatExpectation;

  /// Auto execution blocked until manual recovery streak (server-driven).
  final bool autoShieldEnabled;

  static const DecisionAccuracySnapshot empty = DecisionAccuracySnapshot(
    totalDecisions: 0,
    acceptedCount: 0,
    overrideCount: 0,
    patternTrust: 1.0,
    captionTrust: 1.0,
    timeTrust: 1.0,
    audienceTrust: 1.0,
    captionOverrideCount: 0,
    audienceOverrideCount: 0,
    timeOverrideCount: 0,
    outcomeLearningDeltaPct: null,
    outcomeLearningBeatExpectation: null,
    autoShieldEnabled: false,
  );

  AutoDecisionTrust get dimensionTrust => AutoDecisionTrust(
        captionTrust: captionTrust,
        timeTrust: timeTrust,
        audienceTrust: audienceTrust,
      );

  double get acceptedRate =>
      totalDecisions <= 0 ? 0.0 : acceptedCount / totalDecisions;

  double get modifiedRate =>
      totalDecisions <= 0 ? 0.0 : overrideCount / totalDecisions;

  /// Highest override dimension among caption / audience / time, or null if none.
  String? mostOverriddenKey() {
    final a = captionOverrideCount;
    final b = audienceOverrideCount;
    final c = timeOverrideCount;
    if (a == 0 && b == 0 && c == 0) return null;
    if (a >= b && a >= c) return 'caption';
    if (b >= a && b >= c) return 'audience';
    return 'time';
  }

  static DecisionAccuracySnapshot fromStateMap(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return DecisionAccuracySnapshot.empty;
    int i(String k) {
      final v = data[k];
      if (v is int) return v;
      if (v is num) return v.round();
      return 0;
    }

    final dims = AutoDecisionTrust.fromStateMap(data);
    final trust = data['patternTrust'];
    final pattern = trust is num && trust.isFinite
        ? trust.toDouble().clamp(0.5, 1.0)
        : dims.patternTrustCompatible;

    final od = data['outcomeLearningDeltaPct'];
    double? deltaPct;
    if (od is num && od.isFinite) {
      deltaPct = od.toDouble();
    }

    final beat = data['outcomeLearningBeatExpectation'];
    bool? beatExp;
    if (beat is bool) {
      beatExp = beat;
    }

    return DecisionAccuracySnapshot(
      totalDecisions: i('totalDecisions'),
      acceptedCount: i('acceptedCount'),
      overrideCount: i('overrideCount'),
      patternTrust: pattern,
      captionTrust: dims.captionTrust,
      timeTrust: dims.timeTrust,
      audienceTrust: dims.audienceTrust,
      captionOverrideCount: i('captionOverrideCount'),
      audienceOverrideCount: i('audienceOverrideCount'),
      timeOverrideCount: i('timeOverrideCount'),
      outcomeLearningDeltaPct: deltaPct,
      outcomeLearningBeatExpectation: beatExp,
      autoShieldEnabled: data['autoShieldEnabled'] == true,
    );
  }
}
