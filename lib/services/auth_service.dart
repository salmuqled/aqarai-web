// lib/services/auth_service.dart

import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  /// يحدّث الـ ID Token من السيرفر (مهم بعد تغيير Custom Claims مثل `admin`).
  static Future<void> refreshIdTokenClaims() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await user.getIdToken(true);
    } catch (_) {}
  }

  /// يتحقق إذا المستخدم الحالي يملك admin claim داخل Firebase
  static Future<bool> isAdmin() async {
    final user = FirebaseAuth.instance.currentUser;

    // لو المستخدم مو مسجل دخول
    if (user == null) return false;

    // تحديث الـ Token للحصول على الـ Claims الجديدة
    await user.getIdToken(true);

    final tokenResult = await user.getIdTokenResult();
    final claims = tokenResult.claims;

    return claims?['admin'] == true;
  }
}
