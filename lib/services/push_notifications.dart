// lib/services/push_notifications.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// ✅ نستخدم الخدمة الموحدة الجديدة
import 'package:aqarai_app/services/notification_service.dart';

/// لازم تكون Top-level لمعالجة رسائل الخلفية (iOS/Android)
/// سجّلها في main.dart قبل runApp:
/// FirebaseMessaging.onBackgroundMessage(NotificationService.firebaseMessagingBackgroundHandler);
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // نعيد التوجيه لهاندلر الخدمة الجديدة
  await NotificationService.firebaseMessagingBackgroundHandler(message);
}

/// غلاف متوافق مع الكود القديم
/// - يبقي نفس الاسم PushNotifications.init()
/// - يوجه الإعدادات إلى NotificationService.setup()
class PushNotifications {
  static bool _initialized = false;

  /// استدعها مرة واحدة بعد Firebase.initializeApp
  ///
  /// لو مرّرت [context] نفعّل معالجة الرسائل بالكامل
  /// (عرض Dialog زرّين للتمديد/الحذف عند وصول إشعار).
  ///
  /// لو عندك هذا الجهاز أدمن وتبي توصله تنبيهات انتهاء المدة:
  /// set [subscribeAdmin] = true
  static Future<void> init({
    BuildContext? context,
    bool subscribeAdmin = false,
  }) async {
    if (_initialized) return;
    _initialized = true;

    // 1) طلب صلاحيات التنبيهات (خاصة iOS)
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    // 2) عرض تنبيهات أثناء الـ Foreground على iOS
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );

    // 3) هاندلر الخلفية (لو ما سجلته في main.dart — نسجل هنا أيضًا احتياطًا)
    FirebaseMessaging.onBackgroundMessage(
      NotificationService.firebaseMessagingBackgroundHandler,
    );

    // 4) إن زوّدتنا بـ context نستخدم الخدمة الجديدة لتفعيل
    //    الاستماع للرسائل وفتح الـ Dialog بالزرّين
    if (context != null) {
      await NotificationService.setup(context, subscribeAdmin: subscribeAdmin);
      return;
    }

    // 5) بدون context: نكتفي بالاستماع والطباعة (بدون Dialog)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      // يمكن الإبقاء على الطباعة أو تركه فارغًا
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      // يُمكن التعامل مع فتح الإشعار هنا
    });

    // initialMessage في حال فتح التطبيق من إشعار وهو مغلق
    final initialMsg = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMsg != null) {
      // يُدار لاحقًا عند استدعاء NotificationService.setup(context)
    }
  }
}
