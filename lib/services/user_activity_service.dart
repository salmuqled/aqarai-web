import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// يسجّل نشاطاً خفيفاً في `user_activity/{uid}` لتحسين وقت الإرسال والجمهور (لا يُرسل إشعارات تلقائياً).
abstract final class UserActivityService {
  static const String collection = 'user_activity';

  /// يُستدعى عند فتح التطبيق أو بعد إجراءات مهمّة (مسجّل فقط).
  static Future<void> recordActivity({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    String reason = 'app_open',
  }) async {
    final user = (auth ?? FirebaseAuth.instance).currentUser;
    if (user == null) return;

    final now = DateTime.now();
    final db = firestore ?? FirebaseFirestore.instance;

    try {
      await db.collection(collection).doc(user.uid).set(
        {
          'userId': user.uid,
          'lastSeenAt': FieldValue.serverTimestamp(),
          'lastActiveHour': now.hour,
          'lastActiveDay': now.weekday,
          'lastReason': reason,
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      // لا نعطّل التطبيق إذا فشل التتبع
    }
  }
}
