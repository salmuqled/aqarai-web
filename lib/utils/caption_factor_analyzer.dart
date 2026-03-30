/// Detects caption factors for logging and scoring (aligned with Cloud Function).
abstract final class CaptionFactorAnalyzer {
  CaptionFactorAnalyzer._();

  /// “Short” for usage logs — character budget heuristic.
  static const int shortTextMaxChars = 220;

  static bool hasEmoji(String text) {
    for (final r in text.runes) {
      if (r >= 0x1f300 && r <= 0x1faff) return true;
      if (r >= 0x2600 && r <= 0x27bf) return true;
      if (r >= 0x1f600 && r <= 0x1f64f) return true;
    }
    return false;
  }

  static bool hasArea(String caption, String area) {
    final a = area.trim();
    return a.isNotEmpty && caption.contains(a);
  }

  static bool hasUrgency(String caption) => caption.contains('🔥');

  /// Single-caption “short” flag for [caption_usage_logs].
  static bool shortTextForUsage(String caption) =>
      caption.length <= shortTextMaxChars;

  static Map<String, bool> factorsMap(String captionText, String area) {
    return {
      'hasEmoji': hasEmoji(captionText),
      'hasArea': hasArea(captionText, area),
      'hasUrgency': hasUrgency(captionText),
      'shortText': shortTextForUsage(captionText),
    };
  }
}
