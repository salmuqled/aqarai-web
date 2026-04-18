// lib/services/notification_service.dart
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:device_info_plus/device_info_plus.dart';

// ✅ بدل main.dart
import 'package:aqarai_app/app/navigation_keys.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/pages/admin_deal_detail_page.dart';
import 'package:aqarai_app/pages/assistant_page.dart';
import 'package:aqarai_app/pages/auction_details_page.dart';
import 'package:aqarai_app/pages/owner_dashboard_page.dart';
import 'package:aqarai_app/services/notification_click_tracking_service.dart';
import 'package:aqarai_app/widgets/property_details_page.dart';

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

    // 6) الهاندلرز — تتبع «فتح من الإشعار» فقط عند فتح التطبيق من التنبيه (ليس العرض في المقدّمة).
    FirebaseMessaging.onMessage.listen((m) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = rootNavigatorKey.currentContext;
        if (ctx == null) return;
        _handle(ctx, m, openedFromTap: false);
      });
    });
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = rootNavigatorKey.currentContext;
        if (ctx == null) return;
        _handle(ctx, m, openedFromTap: true);
        unawaited(NotificationClickTrackingService.recordOpenFromNotification(m));
      });
    });

    // 7) إذا تم فتح التطبيق من إشعار وهو مغلق مسبقًا
    final initialMsg = await _fcm.getInitialMessage();
    if (initialMsg != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = rootNavigatorKey.currentContext;
        if (ctx == null) return;
        unawaited(
          NotificationClickTrackingService.recordOpenFromNotification(initialMsg),
        );
        _handle(ctx, initialMsg, openedFromTap: true);
      });
    }

    return token;
  }

  /// Marks server-backed inbox doc read when user opens a commerce push (best-effort).
  static Future<void> _markNotificationOpenedIfPresent(
    Map<String, dynamic> data,
  ) async {
    final id = data['notificationId']?.toString().trim() ?? '';
    if (id.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('notifications')
          .doc(id)
          .update({'isRead': true});
    } catch (e) {
      debugPrint('notifications mark read: $e');
    }
  }

  /// Opens commerce/chalet deep links (inbox, tests) — same behavior as FCM tap.
  static void navigateCommerceDeepLink(Map<String, dynamic> data) {
    _navigateChaletCommerce(Map<String, dynamic>.from(data));
  }

  static void _navigateChaletCommerce(Map<String, dynamic> data) {
    unawaited(_markNotificationOpenedIfPresent(data));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final nav = rootNavigatorKey.currentState;
        if (nav == null) return;

        void pushHome() {
          nav.push(
            MaterialPageRoute<void>(builder: (_) => const AssistantPage()),
          );
        }

        void pushOwnerDashboard() {
          nav.push(
            MaterialPageRoute<void>(
              builder: (_) => const OwnerDashboardPage(),
            ),
          );
        }

        void pushProperty(String pid) {
          final trimmed = pid.trim();
          if (trimmed.isEmpty) {
            pushHome();
            return;
          }
          nav.push(
            MaterialPageRoute<void>(
              builder: (_) => PropertyDetailsPage(
                propertyId: trimmed,
                leadSource: DealLeadSource.direct,
              ),
            ),
          );
        }

        /// Deep link: prefer property; otherwise home (bookingId without property is rare).
        void openBookingDetailsFromData() {
          final propertyId = data['propertyId']?.toString().trim() ?? '';
          final bookingId = data['bookingId']?.toString().trim() ?? '';
          if (propertyId.isNotEmpty) {
            pushProperty(propertyId);
            return;
          }
          if (bookingId.isNotEmpty) {
            pushHome();
            return;
          }
          pushHome();
        }

        final screenRaw = data['screen']?.toString().trim() ?? '';
        final nType = data['notificationType']?.toString() ?? '';

        if (screenRaw == 'payout' ||
            (screenRaw.isEmpty && nType == 'payout')) {
          pushOwnerDashboard();
          return;
        }

        if (screenRaw == 'property' ||
            (screenRaw.isEmpty && nType == 'refund')) {
          final propertyId = data['propertyId']?.toString().trim() ?? '';
          if (propertyId.isNotEmpty) {
            pushProperty(propertyId);
          } else {
            pushHome();
          }
          return;
        }

        if (screenRaw == 'booking' ||
            (screenRaw.isEmpty && nType == 'booking')) {
          openBookingDetailsFromData();
          return;
        }
      } catch (e, st) {
        debugPrint('Chalet FCM navigation failed: $e\n$st');
      }
    });
  }

  static void _presentChaletForegroundSnackBar(
    BuildContext context,
    RemoteMessage message,
  ) {
    final loc = Localizations.localeOf(context);
    final actionLabel = loc.languageCode == 'ar' ? 'عرض' : 'View';
    final body =
        message.notification?.body ?? message.notification?.title ?? '';
    if (body.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = rootNavigatorKey.currentContext ?? context;
      if (!target.mounted) return;
      ScaffoldMessenger.maybeOf(target)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(body),
          action: SnackBarAction(
            label: actionLabel,
            onPressed: () => _navigateChaletCommerce(message.data),
          ),
        ),
      );
    });
  }

  /// يعرض الـ Dialog ويستدعي الCallable حسب زر المستخدم
  static void _handle(
    BuildContext context,
    RemoteMessage message, {
    required bool openedFromTap,
  }) {
    final data = message.data;
    final nType = data['notificationType']?.toString();
    final screenRaw = data['screen']?.toString().trim() ?? '';
    if (nType == 'booking' ||
        nType == 'payout' ||
        nType == 'refund' ||
        screenRaw == 'booking' ||
        screenRaw == 'property' ||
        screenRaw == 'payout') {
      if (openedFromTap) {
        _navigateChaletCommerce(data);
      } else {
        _presentChaletForegroundSnackBar(context, message);
      }
      return;
    }

    final type = data['type']?.toString();

    if (type == DealFollowUpFcmTypes.dealFollowup ||
        type == DealFollowUpFcmTypes.dealFollowupDueLegacy) {
      _navigateToAdminDealDetail(data);
      return;
    }

    switch (type) {
      case AuctionApprovalReminderFcmTypes.oneHour:
        _navigateToAuctionApprovalLot(data);
        return;
      case AuctionApprovalReminderFcmTypes.tenMin:
        _navigateToAuctionApprovalLot(data);
        return;
      case AuctionApprovalReminderFcmTypes.oneMin:
        _navigateToAuctionApprovalLot(data);
        return;
      case AuctionApprovalReminderFcmTypes.legacyDeadlineSoon:
        // خلفية: السيرفر كان يرسل type واحداً مع data.stage
        _navigateToAuctionApprovalLot(data);
        return;
    }

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
  /// فتح صفحة تفاصيل القطعة بعد الضغط على تذكير اعتماد المزاد (FCM).
  /// Opens [AdminDealDetailPage] from FCM `deal_followup` (scheduled follow-up reminders).
  static void _navigateToAdminDealDetail(Map<String, dynamic> data) {
    final dealId = data['dealId']?.toString().trim() ?? '';
    if (dealId.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = rootNavigatorKey.currentState;
      if (nav == null) return;
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => AdminDealDetailPage(dealId: dealId),
        ),
      );
    });
  }

  static void _navigateToAuctionApprovalLot(Map<String, dynamic> data) {
    final lotId = data['lotId']?.toString().trim() ?? '';
    if (lotId.isEmpty) return;
    final auctionRaw = data['auctionId']?.toString().trim() ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = rootNavigatorKey.currentState;
      if (nav == null) return;
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => AuctionDetailsPage(
            lotId: lotId,
            auctionId: auctionRaw.isEmpty ? null : auctionRaw,
          ),
        ),
      );
    });
  }

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

/// قيم `data['type']` لتذكيرات اعتماد المزاد (تطابق Cloud Function).
/// `data['type']` for deal follow-up push (matches Cloud Function payload).
abstract final class DealFollowUpFcmTypes {
  DealFollowUpFcmTypes._();

  static const String dealFollowup = 'deal_followup';

  /// Older scheduled job payloads; still open the same screen.
  static const String dealFollowupDueLegacy = 'deal_followup_due';
}

abstract final class AuctionApprovalReminderFcmTypes {
  AuctionApprovalReminderFcmTypes._();

  static const String oneHour = 'auction_approval_1h';
  static const String tenMin = 'auction_approval_10m';
  static const String oneMin = 'auction_approval_1m';

  /// Payloads أقدم قبل فصل النوع لكل مرحلة (`data.stage` كان اختيارياً).
  static const String legacyDeadlineSoon = 'auction_approval_deadline_soon';
}
