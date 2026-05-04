// lib/services/auth_service.dart

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  /// Shared interpretation of Firebase Auth custom claim `admin` (bool or string).
  static bool isAdminFromClaims(Map<String, dynamic>? claims) {
    final admin = claims?['admin'];
    return admin == true || admin == 'true';
  }

  /// يحدّث الـ ID Token من السيرفر (مهم بعد تغيير Custom Claims مثل `admin`).
  static Future<void> refreshIdTokenClaims() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await user.getIdToken(true);
    } catch (e, st) {
      debugPrint('Error in AuthService.refreshIdTokenClaims: $e\n$st');
    }
  }

  /// يتحقق إذا المستخدم الحالي يملك admin claim داخل Firebase
  static Future<bool> isAdmin() async {
    final user = FirebaseAuth.instance.currentUser;

    // لو المستخدم مو مسجل دخول
    if (user == null) return false;

    // تحديث الـ Token للحصول على الـ Claims الجديدة
    await user.getIdToken(true);

    final tokenResult = await user.getIdTokenResult();
    return isAdminFromClaims(tokenResult.claims);
  }
}
