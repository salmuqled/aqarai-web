/// Result of [AutoDecisionService.generateDecision] for semi-automated marketing.
class AutoDecision {
  const AutoDecision({
    required this.bestHour,
    required this.audienceSegment,
    required this.captionId,
    required this.captionText,
    required this.expectedCtr,
    required this.confidence,
    required this.reason,
    required this.suggestedScheduleAt,
    required this.notificationTitle,
    required this.notificationBody,
    required this.decisionLevel,
  });

  /// `auto` | `review` | `manual` — from confidence vs hybrid thresholds.
  final String decisionLevel;

  /// Local hour 0–23 for scheduling.
  final int bestHour;

  /// `active` | `warm` | `cold` | `all`
  final String audienceSegment;

  /// `A` | `B` | `C`
  final String captionId;

  /// Full chosen caption (e.g. for Instagram); push uses shorter [notificationBody].
  final String captionText;

  /// Rough expected CTR 0…1 (historical variant CTR × audience multiplier, capped).
  final double expectedCtr;

  /// 0…1 composite confidence.
  final double confidence;

  /// Human-readable explanation (locale-specific).
  final String reason;

  /// Next local run at [bestHour] (today or tomorrow).
  final DateTime suggestedScheduleAt;

  /// Suggested FCM title.
  final String notificationTitle;

  /// Suggested FCM body (truncated).
  final String notificationBody;
}
