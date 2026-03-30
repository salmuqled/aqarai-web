/// One ranked Instagram caption variant (A/B/C test).
class CaptionVariantScore {
  const CaptionVariantScore({
    required this.variantId,
    required this.caption,
    required this.score,
  });

  /// `A` | `B` | `C`
  final String variantId;
  final String caption;
  final double score;
}
