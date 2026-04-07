import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:aqarai_app/app/navigation_keys.dart';
import 'package:aqarai_app/pages/admin_deal_detail_page.dart';

/// Minute-level CRM follow-up reminders (complements server FCM backup).
class DealFollowUpLocalNotifications {
  DealFollowUpLocalNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'deal_followup_local';
  static const String _channelName = 'Deal follow-up';
  static const String _channelDesc =
      'Local reminders when a client follow-up is due';

  static const String _title = 'متابعة عميل';
  static const String _body = 'لديك عميل يحتاج متابعة الآن';

  static bool _timezonesLoaded = false;
  static bool _initialized = false;

  /// Set when app was opened from a terminated state via tapping this notification.
  static String? _pendingLaunchDealId;

  /// Stable positive notification id (per deal) for cancel/reschedule.
  static int notificationIdForDeal(String dealId) =>
      dealId.hashCode & 0x7fffffff;

  static Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) {
      _initialized = true;
      return;
    }

    if (!_timezonesLoaded) {
      tzdata.initializeTimeZones();
      _timezonesLoaded = true;
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
      ),
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ),
      );
      await android?.requestNotificationsPermission();
      await android?.requestExactAlarmsPermission();
    }

    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      final p = launch!.notificationResponse?.payload;
      if (p != null && p.isNotEmpty) {
        _pendingLaunchDealId = p;
      }
    }

    _initialized = true;
  }

  static void _onNotificationResponse(NotificationResponse response) {
    final p = response.payload;
    if (p == null || p.isEmpty) return;
    _navigateToDeal(p);
  }

  static void _navigateToDeal(String dealId) {
    final nav = rootNavigatorKey.currentState;
    if (nav != null) {
      nav.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AdminDealDetailPage(dealId: dealId),
        ),
      );
    } else {
      _pendingLaunchDealId = dealId;
    }
  }

  /// Call after the first frame when [rootNavigatorKey] is attached (e.g. [AuthGate]).
  static void flushPendingLaunchNavigation() {
    final id = _pendingLaunchDealId;
    if (id == null || id.isEmpty) return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    _pendingLaunchDealId = null;
    nav.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AdminDealDetailPage(dealId: id),
      ),
    );
  }

  static NotificationDetails _details() {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      macOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }

  /// Cancels any scheduled local reminder for [dealId], then schedules at [at] if in the future.
  static Future<void> rescheduleAfterFollowUpSave({
    required String dealId,
    required DateTime at,
  }) async {
    if (kIsWeb) return;
    if (!_initialized) {
      debugPrint(
        '[DealFollowUpLocalNotifications] initialize() not called; skip schedule',
      );
      return;
    }

    final id = notificationIdForDeal(dealId);
    await _plugin.cancel(id: id);

    final atUtc = at.toUtc();
    final nowUtc = DateTime.now().toUtc();
    if (!atUtc.isAfter(nowUtc)) {
      return;
    }

    final when = tz.TZDateTime.from(atUtc, tz.UTC);

    try {
      await _plugin.zonedSchedule(
        id: id,
        scheduledDate: when,
        notificationDetails: _details(),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        title: _title,
        body: _body,
        payload: dealId,
      );
    } catch (e, st) {
      debugPrint('[DealFollowUpLocalNotifications] zonedSchedule failed: $e');
      debugPrint('$st');
    }
  }

  static Future<void> cancelForDeal(String dealId) async {
    if (kIsWeb) return;
    if (!_initialized) return;
    await _plugin.cancel(id: notificationIdForDeal(dealId));
  }
}
