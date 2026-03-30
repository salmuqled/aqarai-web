/// Learned scoring weights from [caption_learning] (fallback: [defaults]).
class CaptionLearningWeights {
  const CaptionLearningWeights({
    required this.emoji,
    required this.area,
    required this.urgency,
    required this.shortText,
  });

  final double emoji;
  final double area;
  final double urgency;
  final double shortText;

  static const CaptionLearningWeights defaults = CaptionLearningWeights(
    emoji: 0.1,
    area: 0.2,
    urgency: 0.2,
    shortText: 0.1,
  );
}
