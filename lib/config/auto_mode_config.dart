/// Default hybrid marketing thresholds (overridable in admin settings / SharedPreferences).
abstract final class AutoModeConfig {
  AutoModeConfig._();

  static const double autoThreshold = 0.9;
  static const double reviewThreshold = 0.7;

  static const double autoThresholdMin = 0.8;
  static const double autoThresholdMax = 0.95;
  static const double reviewThresholdMin = 0.6;
  static const double reviewThresholdMax = 0.85;

  /// Strict auto eligibility (all must pass or UI falls back to review).
  static const double strictAutoMinExpectedCtr = 0.25;
  static const double strictAutoMinCaptionTrust = 0.8;
  static const double strictAutoMinTimeTrust = 0.75;
  static const double strictAutoMinAudienceTrust = 0.75;

  /// Dynamic countdown: null = no automatic timer (still shows Run now).
  static int? autoCountdownSecondsForConfidence(double confidence) {
    if (confidence > 0.95) return 3;
    if (confidence > 0.9) return 5;
    return null;
  }
}
