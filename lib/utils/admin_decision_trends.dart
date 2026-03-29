import 'package:aqarai_app/models/admin_recommendation.dart';

/// Difference in the same units as [current] and [previous] (e.g. both 0–1 rates → delta is in rate units).
double calculateChange(double current, double previous) => current - previous;

/// Maps a numeric delta to [AdminRecommendationTrend] values (exactly 0 → stable).
String getTrend(double change) {
  if (change > 0) return AdminRecommendationTrend.up;
  if (change < 0) return AdminRecommendationTrend.down;
  return AdminRecommendationTrend.stable;
}
