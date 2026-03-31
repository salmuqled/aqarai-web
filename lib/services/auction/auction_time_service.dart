import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:ntp/ntp.dart';

/// Hybrid auction clock: **NTP → Firebase `getServerTime` → device offset 0**.
///
/// Never throws from [now]; [sync] is best-effort. UI can listen to
/// [reliableTime] for a subtle warning when only device time is used.
class AuctionTimeService {
  AuctionTimeService._();

  static final AuctionTimeService instance = AuctionTimeService._();

  int _offsetMs = 0;
  bool _synced = false;
  bool _isSyncing = false;

  /// After first successful NTP/Firebase offset; later updates use smoothing.
  bool _hasReceivedExternalOffset = false;

  /// After [sync], `true` if offset came from NTP or Firebase (not raw device).
  bool get hasReliableClock => _synced;

  /// `true` until a sync proves we only have device time (`false` then).
  final ValueNotifier<bool> reliableTime = ValueNotifier<bool>(true);

  Timer? _periodicResync;

  FirebaseFunctions _functions() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  void _applyExternalOffset(int newOffsetMs) {
    if (!_hasReceivedExternalOffset) {
      _offsetMs = newOffsetMs;
      _hasReceivedExternalOffset = true;
    } else {
      final blended =
          (_offsetMs * 0.8) + (newOffsetMs * 0.2);
      _offsetMs = blended.round();
    }
  }

  void _applyDeviceFallback() {
    _offsetMs = 0;
    _synced = false;
    reliableTime.value = false;
    _hasReceivedExternalOffset = false;
  }

  /// Best-effort offset sync (NTP first, then callable `getServerTime`).
  Future<void> sync() async {
    if (_isSyncing) return;
    _isSyncing = true;
    try {
      try {
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final ntpTime = await NTP.now(
          timeout: const Duration(seconds: 3),
        );
        final t1 = DateTime.now().millisecondsSinceEpoch;
        final estDeviceMs = (t0 + t1) >> 1;
        final newOffset = ntpTime.millisecondsSinceEpoch - estDeviceMs;
        _applyExternalOffset(newOffset);
        _synced = true;
        reliableTime.value = true;
        return;
      } catch (_) {
        // continue to Firebase
      }

      try {
        final callable = _functions().httpsCallable('getServerTime');
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final res = await callable.call<dynamic>(<String, dynamic>{});
        final t1 = DateTime.now().millisecondsSinceEpoch;
        final estDeviceMs = (t0 + t1) >> 1;
        final raw = res.data;
        int? serverMs;
        if (raw is Map) {
          final v = raw['nowMs'];
          if (v is num) serverMs = v.round();
        }
        if (serverMs != null) {
          final newOffset = serverMs - estDeviceMs;
          _applyExternalOffset(newOffset);
          _synced = true;
          reliableTime.value = true;
          return;
        }
      } catch (_) {
        // final fallback below
      }

      _applyDeviceFallback();
    } finally {
      _isSyncing = false;
    }
  }

  /// Wall clock adjusted by last successful offset (or device if none).
  DateTime now() {
    final deviceNow = DateTime.now().millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(deviceNow + _offsetMs);
  }

  /// Re-sync every 30 seconds while active (e.g. live auction screen).
  void startPeriodicResync() {
    _periodicResync ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(sync()),
    );
  }

  void stopPeriodicResync() {
    _periodicResync?.cancel();
    _periodicResync = null;
  }
}
