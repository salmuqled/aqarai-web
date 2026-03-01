// lib/services/auth_service.dart

import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
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
