/// Metadata for logging when an admin copies or applies a caption variant.
class CaptionUsageContext {
  const CaptionUsageContext({
    required this.area,
    required this.propertyType,
    required this.demandLevel,
    required this.dealsCount,
  });

  final String area;
  final String propertyType;
  final String demandLevel;
  final int dealsCount;
}
