import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/services/upload_events_service.dart';

/// Alert thresholds (admin Upload Health).
abstract final class UploadHealthThresholds {
  UploadHealthThresholds._();

  /// Flag when [UploadHealthSnapshot.successRate] &lt; this.
  static const double minSuccessRate = 0.9;

  /// Flag when [UploadHealthSnapshot.failureRate] &gt; this.
  static const double maxFailureRate = 0.1;

  /// Flag when [UploadHealthSnapshot.retryRate] &gt; this.
  static const double maxRetryRate = 0.2;
}

/// Aggregates [upload_events] for the admin Upload Health dashboard.
class UploadHealthSnapshot {
  const UploadHealthSnapshot({
    required this.totalStarted,
    required this.totalSuccess,
    required this.totalFailed,
    required this.totalRetry,
    required this.windowStart,
  });

  final int totalStarted;
  final int totalSuccess;
  final int totalFailed;
  final int totalRetry;
  final DateTime windowStart;

  /// [totalSuccess] / [totalStarted]
  double? get successRate =>
      totalStarted > 0 ? totalSuccess / totalStarted : null;

  /// [totalFailed] / [totalStarted]
  double? get failureRate =>
      totalStarted > 0 ? totalFailed / totalStarted : null;

  /// [totalRetry] / [totalStarted]
  double? get retryRate => totalStarted > 0 ? totalRetry / totalStarted : null;

  /// Requires sample: [totalStarted] &gt; 0. Compares against [UploadHealthThresholds].
  bool get hasReliabilityIssue {
    if (totalStarted <= 0) return false;
    final sr = successRate;
    final fr = failureRate;
    final rr = retryRate;
    if (sr == null || fr == null || rr == null) return false;
    return sr < UploadHealthThresholds.minSuccessRate ||
        fr > UploadHealthThresholds.maxFailureRate ||
        rr > UploadHealthThresholds.maxRetryRate;
  }

  /// Non-empty when [hasReliabilityIssue] is true (for logging / UI hints).
  List<String> get reliabilityBreachTags {
    if (totalStarted <= 0) return const [];
    final out = <String>[];
    final sr = successRate;
    final fr = failureRate;
    final rr = retryRate;
    if (sr != null && sr < UploadHealthThresholds.minSuccessRate) {
      out.add('success_below_${UploadHealthThresholds.minSuccessRate}');
    }
    if (fr != null && fr > UploadHealthThresholds.maxFailureRate) {
      out.add('failure_above_${UploadHealthThresholds.maxFailureRate}');
    }
    if (rr != null && rr > UploadHealthThresholds.maxRetryRate) {
      out.add('retry_above_${UploadHealthThresholds.maxRetryRate}');
    }
    return out;
  }

  /// JSON-safe map for [system_alerts.metrics].
  Map<String, dynamic> toMetricsMap({required String windowLabel}) {
    return {
      'windowLabel': windowLabel,
      'windowStart': windowStart.toIso8601String(),
      'totalStarted': totalStarted,
      'totalSuccess': totalSuccess,
      'totalFailed': totalFailed,
      'totalRetry': totalRetry,
      'successRate': successRate,
      'failureRate': failureRate,
      'retryRate': retryRate,
      'thresholds': {
        'minSuccessRate': UploadHealthThresholds.minSuccessRate,
        'maxFailureRate': UploadHealthThresholds.maxFailureRate,
        'maxRetryRate': UploadHealthThresholds.maxRetryRate,
      },
      'breaches': reliabilityBreachTags,
    };
  }
}

abstract final class UploadHealthService {
  UploadHealthService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<int> _countSince({
    required String eventType,
    required Timestamp since,
  }) async {
    final agg = await _db
        .collection('upload_events')
        .where('eventType', isEqualTo: eventType)
        .where('timestamp', isGreaterThanOrEqualTo: since)
        .count()
        .get();
    return agg.count ?? 0;
  }

  /// Loads counts for [window] ending now (Firestore server time approximated by client `since`).
  static Future<UploadHealthSnapshot> load({required Duration window}) async {
    final windowStart = DateTime.now().subtract(window);
    final since = Timestamp.fromDate(windowStart);

    final results = await Future.wait<int>([
      _countSince(
        eventType: PropertyImageUploadEventType.imageUploadStarted,
        since: since,
      ),
      _countSince(
        eventType: PropertyImageUploadEventType.imageUploadSuccess,
        since: since,
      ),
      _countSince(
        eventType: PropertyImageUploadEventType.imageUploadFailed,
        since: since,
      ),
      _countSince(
        eventType: PropertyImageUploadEventType.imageUploadRetry,
        since: since,
      ),
    ]);

    return UploadHealthSnapshot(
      totalStarted: results[0],
      totalSuccess: results[1],
      totalFailed: results[2],
      totalRetry: results[3],
      windowStart: windowStart,
    );
  }
}
