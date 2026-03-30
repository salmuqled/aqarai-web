import 'package:aqarai_app/config/auto_mode_config.dart';

/// Hybrid marketing automation thresholds (stored in Firestore `admin_settings/global`).
class HybridMarketingSettings {
  const HybridMarketingSettings({
    required this.autoExecutionEnabled,
    required this.autoThreshold,
    required this.reviewThreshold,
  });

  final bool autoExecutionEnabled;
  final double autoThreshold;
  final double reviewThreshold;

  /// Auto off by default; thresholds match [AutoModeConfig].
  static const HybridMarketingSettings defaults = HybridMarketingSettings(
    autoExecutionEnabled: false,
    autoThreshold: AutoModeConfig.autoThreshold,
    reviewThreshold: AutoModeConfig.reviewThreshold,
  );

  static double _readDouble(dynamic v, double fallback) {
    if (v is num && v.isFinite) return v.toDouble();
    return fallback;
  }

  /// Parses Firestore map; missing/invalid fields use [defaults] then [copyWith] clamps.
  static HybridMarketingSettings fromFirestoreMap(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return defaults;
    return HybridMarketingSettings(
      autoExecutionEnabled: data['hybridAutoExecutionEnabled'] == true,
      autoThreshold: _readDouble(
        data['hybridAutoThreshold'],
        defaults.autoThreshold,
      ),
      reviewThreshold: _readDouble(
        data['hybridReviewThreshold'],
        defaults.reviewThreshold,
      ),
    ).copyWith();
  }

  HybridMarketingSettings copyWith({
    bool? autoExecutionEnabled,
    double? autoThreshold,
    double? reviewThreshold,
  }) {
    var a = autoThreshold ?? this.autoThreshold;
    var r = reviewThreshold ?? this.reviewThreshold;
    a = a.clamp(
      AutoModeConfig.autoThresholdMin,
      AutoModeConfig.autoThresholdMax,
    );
    r = r.clamp(
      AutoModeConfig.reviewThresholdMin,
      AutoModeConfig.reviewThresholdMax,
    );
    if (r >= a) {
      r = (a - 0.05).clamp(
        AutoModeConfig.reviewThresholdMin,
        a - 0.01,
      );
    }
    return HybridMarketingSettings(
      autoExecutionEnabled:
          autoExecutionEnabled ?? this.autoExecutionEnabled,
      autoThreshold: a,
      reviewThreshold: r,
    );
  }
}
