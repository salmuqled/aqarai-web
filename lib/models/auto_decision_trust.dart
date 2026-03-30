/// Per-dimension trust from [auto_decision_learning/state] (0.5…1.0).
class AutoDecisionTrust {
  const AutoDecisionTrust({
    required this.captionTrust,
    required this.timeTrust,
    required this.audienceTrust,
  });

  final double captionTrust;
  final double timeTrust;
  final double audienceTrust;

  double get averageTrust =>
      (captionTrust + timeTrust + audienceTrust) / 3.0;

  /// For legacy [patternTrust] consumers: average of dimensions.
  double get patternTrustCompatible => averageTrust;

  /// `caption` | `time` | `audience` — lowest trust; null if all equal.
  String? weakestKey() {
    const keys = ['caption', 'time', 'audience'];
    final vals = [captionTrust, timeTrust, audienceTrust];
    var minI = 0;
    for (var i = 1; i < 3; i++) {
      if (vals[i] < vals[minI]) minI = i;
    }
    if (vals.every((v) => (v - vals[minI]).abs() < 1e-9)) return null;
    return keys[minI];
  }

  static const AutoDecisionTrust defaults = AutoDecisionTrust(
    captionTrust: 1.0,
    timeTrust: 1.0,
    audienceTrust: 1.0,
  );

  static AutoDecisionTrust fromStateMap(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return AutoDecisionTrust.defaults;

    double readDim(String key) {
      final v = data[key];
      if (v is num && v.isFinite) return v.toDouble().clamp(0.5, 1.0);
      return -1.0;
    }

    var c = readDim('captionTrust');
    var t = readDim('timeTrust');
    var a = readDim('audienceTrust');
    final p = data['patternTrust'];
    final pattern = p is num && p.isFinite
        ? p.toDouble().clamp(0.5, 1.0)
        : 1.0;
    if (c < 0) c = pattern;
    if (t < 0) t = pattern;
    if (a < 0) a = pattern;

    return AutoDecisionTrust(
      captionTrust: c.clamp(0.5, 1.0),
      timeTrust: t.clamp(0.5, 1.0),
      audienceTrust: a.clamp(0.5, 1.0),
    );
  }
}
