// lib/services/notification_service.dart
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:device_info_plus/device_info_plus.dart';

// ✅ بدل main.dart
import 'package:aqarai_app/app/navigation_keys.dart';

// ✅ للتهيئة الآمنة داخل الهاندلر الخلفي
import 'package:firebase_core/firebase_core.dart';
import 'package:aqarai_app/firebase_options.dart';

/// هاندلر الخلفية يجب أن يكون top-level.
/// سجّله في main.dart:
/// FirebaseMessaging.onBackgroundMessage(NotificationService.firebaseMessagingBackgroundHandler);
@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage message) async {
  // ✅ تأكد من تهيئة Firebase قبل أي استخدام داخل isolate الخلفي
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }

  // ملاحظات: لا تعرض Dialog هنا — فقط تعامل خفيف إن احتجت (logging, local cache).
}

class NotificationService {
  static final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  /// لتسهيل التسجيل من main.dart
  static Future<void> firebaseMessagingBackgroundHandler(
    RemoteMessage message,
  ) {
    return _bgHandler(message);
  }

  /// استدعها مرة واحدة (مثلاً في HomePage) بعد Firebase.initializeApp
  /// [subscribeAdmin] = true إذا كان هذا الجهاز لأدمن (للاشتراك في توبك admins)
  static Future<String?> setup(
    BuildContext context, {
    bool subscribeAdmin = false,
  }) async {
    // 1) طلب الصلاحيات (iOS ينتج نافذة سماح)
    await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );

    // 2) عرض تنبيهات أثناء وجود التطبيق في الواجهة على iOS
    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // 3) الاشتراك للأدمن
    if (subscribeAdmin) {
      try {
        await _fcm.subscribeToTopic('admins');
      } catch (_) {}
    }

    // 4) الحصول على التوكن بأمان (تجنب كراش السيموليتر ومشاكل APNs)
    String? token;
    try {
      if (Platform.isIOS) {
        final deviceInfo = DeviceInfoPlugin();
        final ios = await deviceInfo.iosInfo;
        final isPhysical = ios.isPhysicalDevice;

        if (!isPhysical) {
          // السيموليتر ما يدعم Push حقيقي → لا تطلب FCM token
          debugPrint('⚠️ [Push] iOS Simulator detected → skipping getToken().');
        } else {
          final apns = await _fcm.getAPNSToken();
          if (apns == null) {
            // APNs ناقص في المشروع أو في الجهاز
            debugPrint(
              '⚠️ [Push] APNs token is null on physical device. '
              'تأكد من رفع APNs .p8 في Firebase وتفعيل Push + Background Modes في Xcode.',
            );
          } else {
            token = await _fcm.getToken();
          }
        }
      } else {
        // أندرويد (وغيره)
        token = await _fcm.getToken();
      }
      if (token != null) {
        debugPrint('🎯 FCM token: $token');
        final user = FirebaseAuth.instance.currentUser;
        if (user != null && token.isNotEmpty) {
          try {
            await FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .set({'fcmToken': token}, SetOptions(merge: true));
          } catch (e) {
            debugPrint('❌ [Push] save fcmToken to Firestore failed: $e');
          }
        }
      }
    } catch (e) {
      // منع الكراش: بعض البيئات ترجع "cannot parse response" أو "network lost"
      debugPrint('❌ [Push] getToken failed: $e');
    }

    // 5) عند تجديد التوكن — احفظه في Firestore
    _fcm.onTokenRefresh.listen((newToken) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && newToken.isNotEmpty) {
        FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .set({'fcmToken': newToken}, SetOptions(merge: true))
            .catchError((e) => debugPrint('❌ [Push] onTokenRefresh save failed: $e'));
      }
    });

    // 6) الهاندلرز
    FirebaseMessaging.onMessage.listen((m) => _handle(context, m));
    FirebaseMessaging.onMessageOpenedApp.listen((m) => _handle(context, m));

    // 7) إذا تم فتح التطبيق من إشعار وهو مغلق مسبقًا
    final initialMsg = await _fcm.getInitialMessage();
    if (initialMsg != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handle(context, initialMsg);
      });
    }

    return token;
  }

  /// يعرض الـ Dialog ويستدعي الCallable حسب زر المستخدم
  static void _handle(BuildContext context, RemoteMessage message) {
    final data = message.data;
    final actionType = data['actionType']; // rent_status | sale_status
    final propertyId = data['propertyId'];
    final yesStatus = data['action_yes']; // hard_delete
    final noStatus = data['action_no']; // still_active
    final origin = data['origin']; // weekly | expiry | expiry_admin (للإدمن)

    if (propertyId == null || actionType == null) return;

    // ما نعرض Dialog لإشعار الإدمن العام (نكتفي بالتنبيه داخل لوحة المتابعة)
    if (origin == 'expiry_admin') return;

    final rent = actionType == 'rent_status';
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';

    final isExpiry = origin == 'expiry';
    final title = isArabic
        ? (isExpiry
            ? (rent ? 'انتهت مدة إعلان الإيجار' : 'انتهت مدة إعلان البيع')
            : (rent ? 'تذكير أسبوعي لإعلان الإيجار' : 'تذكير أسبوعي لإعلان البيع'))
        : (isExpiry
            ? (rent ? 'Rental listing expired' : 'Sale listing expired')
            : (rent ? 'Weekly reminder: Rent listing' : 'Weekly reminder: Sale listing'));

    final question = isArabic
        ? (rent ? 'هل تم تأجير العقار؟' : 'هل تم بيع العقار؟')
        : (rent ? 'Has the property been rented?' : 'Has the property been sold?');

    final yesLabel = isArabic ? (rent ? 'تم التأجير' : 'تم البيع') : (rent ? 'Rented' : 'Sold');
    final noLabel = isArabic ? (rent ? 'لم يتم التأجير' : 'لا زال متاح') : 'Still available';

    // تجنّب تعدد الحوارات — اغلق السابق إن وُجد
    final rootNav = rootNavigatorKey.currentState;
    if (rootNav != null && rootNav.canPop()) {
      rootNav.pop();
    }

    showDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: !isExpiry,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(question),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await _callUpdateListingStatus(
                  propertyId,
                  noStatus ?? 'still_active',
                );
              } finally {
                final nav = rootNavigatorKey.currentState;
                if (nav != null && nav.canPop()) nav.pop();
              }
            },
            child: Text(noLabel),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                await _callUpdateListingStatus(
                  propertyId,
                  yesStatus ?? 'hard_delete',
                );
              } finally {
                final nav = rootNavigatorKey.currentState;
                if (nav != null && nav.canPop()) nav.pop();
              }
            },
            child: Text(yesLabel),
          ),
        ],
      ),
    );
  }

  /// يستدعي Callable: updateListingStatus
  static Future<void> _callUpdateListingStatus(
    String propertyId,
    String newStatus,
  ) async {
    final fn = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable('updateListingStatus');
    await fn.call({'propertyId': propertyId, 'newStatus': newStatus});
  }

  /// (اختياري) حذف نهائي مباشر باستدعاء مستقل
  static Future<void> callHardDeleteListing(String propertyId) async {
    final fn = FirebaseFunctions.instanceFor(
      region: 'us-central1',
    ).httpsCallable('hardDeleteListing');
    await fn.call({'propertyId': propertyId});
  }

  /// احصل على التوكن الحالي (لو احتجته عند إنشاء الإعلان)
  static Future<String?> getToken() async {
    try {
      return await _fcm.getToken();
    } catch (_) {
      return null;
    }
  }

  /// تحديث الاشتراك في Topic الإدمن (تقدر تناديها عند تغيّر الصلاحية)
  static Future<void> toggleAdminTopic(bool subscribe) async {
    try {
      if (subscribe) {
        await _fcm.subscribeToTopic('admins');
      } else {
        await _fcm.unsubscribeFromTopic('admins');
      }
    } catch (_) {}
  }
}
