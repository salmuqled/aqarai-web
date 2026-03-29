/// عوامل نص الإشعار المُخزَّنة في `notification_logs.factors` و`notification_learning`.
class NotificationLearningFactors {
  const NotificationLearningFactors({
    required this.hasEmoji,
    required this.hasArea,
    required this.hasUrgency,
    required this.shortText,
  });

  final bool hasEmoji;
  final bool hasArea;
  final bool hasUrgency;
  final bool shortText;

  Map<String, dynamic> toFirestoreMap() => {
        'hasEmoji': hasEmoji,
        'hasArea': hasArea,
        'hasUrgency': hasUrgency,
        'shortText': shortText,
      };

  static NotificationLearningFactors? tryParse(Map<String, dynamic>? m) {
    if (m == null) return null;
    bool b(String k) => m[k] == true;
    return NotificationLearningFactors(
      hasEmoji: b('hasEmoji'),
      hasArea: b('hasArea'),
      hasUrgency: b('hasUrgency'),
      shortText: b('shortText'),
    );
  }
}
