/// Aggregated caption marketing stats for admin dashboard + variant scoring.
class CaptionPerformance {
  const CaptionPerformance({
    required this.captionId,
    required this.clicks,
    required this.impressions,
    required this.ctr,
  });

  final String captionId;
  final int clicks;
  final int impressions;

  /// Clicks ÷ max(impressions, 1). In [0, 1+] if clicks exceed logged usages.
  final double ctr;
}
