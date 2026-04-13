import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'package:aqarai_app/services/system_alerts_service.dart';

/// Sends admin-only [system_alerts] for uncaught client errors so they appear
/// under Control Center → System alerts (no email).
abstract final class AdminClientErrorReporter {
  AdminClientErrorReporter._();

  static final Map<String, DateTime> _lastByFingerprint = <String, DateTime>{};

  static Duration get _cooldown =>
      kDebugMode ? const Duration(seconds: 90) : const Duration(minutes: 20);

  static void scheduleReport(Object error, StackTrace? stack) {
    unawaited(_report(error, stack));
  }

  static Future<void> _report(Object error, StackTrace? stack) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final claims = (await user.getIdTokenResult()).claims;
      final a = claims?['admin'];
      if (a != true && a != 'true') return;

      final fp =
          '${error.runtimeType}_${error.toString().hashCode.abs()}';
      final now = DateTime.now();
      final prev = _lastByFingerprint[fp];
      if (prev != null && now.difference(prev) < _cooldown) return;
      _lastByFingerprint[fp] = now;

      final buf = StringBuffer()..writeln(error.toString());
      if (stack != null) {
        buf.writeln();
        buf.writeln(stack.toString().split('\n').take(14).join('\n'));
      }
      var detail = buf.toString();
      if (detail.length > 1500) {
        detail = detail.substring(0, 1500);
      }

      await SystemAlertsService.logClientError(
        fingerprint: fp.length > 200 ? fp.substring(0, 200) : fp,
        exceptionType: error.runtimeType.toString().length > 200
            ? error.runtimeType.toString().substring(0, 200)
            : error.runtimeType.toString(),
        detail: detail,
      );
    } catch (e, st) {
      debugPrint('[AdminClientErrorReporter] skipped: $e\n$st');
    }
  }
}
