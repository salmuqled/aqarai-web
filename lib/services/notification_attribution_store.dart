import 'package:shared_preferences/shared_preferences.dart';

/// تخزين محلي لآخر إشعار نُقر عليه (للسياق فقط؛ المصدر الأساسي لربط الصفقة هو `users/{uid}`).
abstract final class NotificationAttributionStore {
  static const _kId = 'aqarai_last_notification_id';
  static const _kAtMs = 'aqarai_last_notification_clicked_at_ms';

  static Future<void> saveLastClick({
    required String notificationId,
    required DateTime clickedAt,
  }) async {
    if (notificationId.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kId, notificationId);
    await p.setInt(_kAtMs, clickedAt.millisecondsSinceEpoch);
  }

  static Future<({String? id, DateTime? at})> readLastClick() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getString(_kId);
    final ms = p.getInt(_kAtMs);
    if (id == null || id.isEmpty || ms == null) {
      return (id: null, at: null);
    }
    return (id: id, at: DateTime.fromMillisecondsSinceEpoch(ms));
  }

  /// هل النقر الأخير ضمن النافذة (افتراض 48 ساعة)؟
  static bool isWithinWindow(DateTime? at, {int maxHours = 48}) {
    if (at == null) return false;
    final h = DateTime.now().difference(at).inHours;
    return h >= 0 && h <= maxHours;
  }
}
