// lib/services/chat_analytics_service.dart
//
// Lightweight, fire-and-forget analytics pipeline for the AI chat funnel.
//
// NOTE: Do NOT confuse with [AnalyticsService] in `analytics_service.dart` —
// that class aggregates business-metric counters on `analytics/global`
// (deals, volume, commission). This service writes per-event rows to a
// separate `analytics_events/` collection for the chat funnel (suggestion
// impressions, clicks, searches, etc.).
//
// Contract:
//   - `logEvent(eventType, data)` returns immediately (synchronous enqueue).
//   - Events are buffered in memory and flushed to Firestore
//     `analytics_events/` in batches. No network call happens on the UI path.
//   - All failures are swallowed silently. The UI must never see an exception
//     from this service.
//
// Firestore document shape (matches the spec exactly):
//   {
//     eventType: string,
//     userId:    string,       // auth uid
//     data:      map,          // caller-supplied payload
//     createdAt: timestamp,    // client-side capture time
//   }
//
// In addition we stamp `serverReceivedAt: serverTimestamp` and `clientEpochMs`
// so downstream BI can reason about clock skew, but those are additive and
// do not violate the specified schema.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

class ChatAnalyticsService {
  ChatAnalyticsService._internal();
  static final ChatAnalyticsService _instance =
      ChatAnalyticsService._internal();
  factory ChatAnalyticsService() => _instance;

  // ---------------------------------------------------------------------------
  // Tunables
  // ---------------------------------------------------------------------------

  /// Trigger an immediate flush once the queue reaches this size.
  static const int _flushThreshold = 15;

  /// Hard cap on in-memory queue. If exceeded, oldest events are dropped.
  static const int _maxQueueSize = 500;

  /// Maximum docs per Firestore commit.
  static const int _batchCommitLimit = 400;

  /// Idle flush interval: if no new event arrives, flush whatever is buffered.
  static const Duration _idleFlushInterval = Duration(seconds: 5);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  final List<_PendingEvent> _queue = <_PendingEvent>[];
  Timer? _idleTimer;
  bool _flushInFlight = false;
  bool _disabled = false;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Enqueue an analytics event. Safe to call from any code path, including
  /// tight UI paths. Never throws.
  void logEvent(String eventType, Map<String, dynamic> data) {
    if (_disabled) return;
    try {
      if (eventType.isEmpty) return;

      if (_queue.length >= _maxQueueSize) {
        _queue.removeRange(0, 50);
      }

      _queue.add(_PendingEvent(
        eventType: eventType,
        data: _sanitize(data),
        capturedAt: DateTime.now(),
      ));

      if (_queue.length >= _flushThreshold) {
        _scheduleImmediateFlush();
      } else {
        _armIdleTimer();
      }
    } catch (e, st) {
      _debug('enqueue failure: $e\n$st');
    }
  }

  /// Flush any buffered events right now. Intended for lifecycle hooks
  /// (app paused / detached) or tests. Always resolves, never throws.
  Future<void> flushNow() async {
    try {
      await _flush();
    } catch (_) {/* silent */}
  }

  /// Emergency off switch. Used if rules deploy hasn't landed yet and we want
  /// to prevent log spam. Can be toggled at runtime from remote config, etc.
  void disable() {
    _disabled = true;
    _queue.clear();
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleFlushInterval, () {
      _idleTimer = null;
      _scheduleImmediateFlush();
    });
  }

  void _scheduleImmediateFlush() {
    // ignore: discarded_futures
    _flush();
  }

  Future<void> _flush() async {
    if (_flushInFlight) return;
    if (_queue.isEmpty) return;
    _flushInFlight = true;

    try {
      final take = _queue.length > _batchCommitLimit
          ? _batchCommitLimit
          : _queue.length;
      final pending = _queue.sublist(0, take);
      _queue.removeRange(0, take);

      final uid = _currentUid();
      if (uid == null) {
        _debug('skipping flush: no auth session');
        return;
      }

      final firestore = FirebaseFirestore.instance;
      final col = firestore.collection('analytics_events');
      final batch = firestore.batch();

      for (final e in pending) {
        final ref = col.doc();
        batch.set(ref, <String, dynamic>{
          'eventType': e.eventType,
          'userId': uid,
          'data': e.data,
          'createdAt': Timestamp.fromDate(e.capturedAt),
          'clientEpochMs': e.capturedAt.millisecondsSinceEpoch,
          'serverReceivedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      if (_queue.isNotEmpty) {
        // ignore: discarded_futures
        Future<void>.microtask(_flush);
      }
    } catch (e) {
      _debug('flush failure: $e');
    } finally {
      _flushInFlight = false;
    }
  }

  String? _currentUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  /// Defensive deep-copy of a caller-supplied map, stripping anything we
  /// cannot safely round-trip through Firestore (closures, widgets, etc.).
  Map<String, dynamic> _sanitize(Map<String, dynamic> raw) {
    final out = <String, dynamic>{};
    raw.forEach((k, v) {
      final cleaned = _sanitizeValue(v);
      if (cleaned != null || v == null) {
        out[k] = cleaned;
      }
    });
    return out;
  }

  Object? _sanitizeValue(Object? v) {
    if (v == null) return null;
    if (v is num || v is bool || v is String) return v;
    if (v is DateTime) return Timestamp.fromDate(v);
    if (v is Timestamp) return v;
    if (v is Iterable) {
      return v.map(_sanitizeValue).where((e) => e != null).toList();
    }
    if (v is Map) {
      final m = <String, dynamic>{};
      v.forEach((k, val) {
        final cleaned = _sanitizeValue(val);
        if (cleaned != null) m[k.toString()] = cleaned;
      });
      return m;
    }
    return v.toString();
  }

  void _debug(String msg) {
    if (kDebugMode) {
      debugPrint('[ChatAnalyticsService] $msg');
    }
  }
}

class _PendingEvent {
  _PendingEvent({
    required this.eventType,
    required this.data,
    required this.capturedAt,
  });

  final String eventType;
  final Map<String, dynamic> data;
  final DateTime capturedAt;
}

/// Canonical event-type constants. Using constants instead of raw strings
/// prevents typos from fragmenting the analytics stream across builds.
class ChatAnalyticsEvents {
  ChatAnalyticsEvents._();

  static const String suggestionImpression = 'suggestion_impression';
  static const String suggestionClick = 'suggestion_click';
  static const String suggestionResult = 'suggestion_result';
  static const String searchExecuted = 'search_executed';
  static const String searchEmpty = 'search_empty';
}
