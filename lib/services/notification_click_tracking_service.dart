import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:aqarai_app/services/notification_attribution_store.dart';

/// تسجيل فتح التطبيق من إشعار (FCM) في [notification_clicks].
///
/// آمن تجاه البيانات الناقصة؛ لا يُرمى إذا لم يكن المستخدم مسجّلاً.
abstract final class NotificationClickTrackingService {
  static const int _maxTitleLen = 300;

  static Future<void> recordOpenFromNotification(RemoteMessage message) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) return;

      final data = message.data;
      final id = data['notificationId']?.toString().trim();
      final variantId = data['variantId']?.toString().trim();
      String? title = message.notification?.title?.trim();
      title ??= data['title']?.toString().trim();
      if (title != null && title.length > _maxTitleLen) {
        title = title.substring(0, _maxTitleLen);
      }

      final now = FieldValue.serverTimestamp();
      final payload = <String, dynamic>{
        'userId': uid,
        'openedAt': now,
        'clickedAt': now,
      };
      if (id != null && id.isNotEmpty) {
        payload['notificationId'] = id;
      }
      if (variantId != null && variantId.isNotEmpty) {
        payload['variantId'] = variantId;
      }
      if (title != null && title.isNotEmpty) {
        payload['notificationTitle'] = title;
      }

      await FirebaseFirestore.instance.collection('notification_clicks').add(payload);

      if (id != null && id.isNotEmpty) {
        final clickedLocal = DateTime.now();
        await NotificationAttributionStore.saveLastClick(
          notificationId: id,
          clickedAt: clickedLocal,
        );
        await FirebaseFirestore.instance.collection('users').doc(uid).set(
          {
            'lastClickedNotificationId': id,
            'lastClickedNotificationAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }
    } catch (e, st) {
      debugPrint('NotificationClickTrackingService: $e\n$st');
    }
  }
}
