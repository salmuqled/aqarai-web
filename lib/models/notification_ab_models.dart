/// نتيجة [AdminAnalyticsService.getBestNotificationVariant] (أفضل نسخة في أحدث حملة A/B).
class BestNotificationVariant {
  const BestNotificationVariant({
    required this.variantText,
    required this.ctr,
    required this.sentCount,
    required this.clickCount,
    required this.variantId,
    required this.notificationLogId,
    required this.abCampaignId,
  });

  final String variantText;
  final double ctr;
  final int sentCount;
  final int clickCount;
  final String variantId;
  final String notificationLogId;
  final String abCampaignId;
}
