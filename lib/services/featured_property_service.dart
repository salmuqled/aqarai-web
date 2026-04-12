import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;

/// Server-authoritative featuring for `properties/{id}.featuredUntil`.
abstract final class FeaturedPropertyService {
  FeaturedPropertyService._();

  static const String _region = 'us-central1';
  static const String _callableName = 'featureProperty';
  static const String _callableMockName = 'featurePropertyMock';
  static const String _callablePaidName = 'featurePropertyPaid';

  static FirebaseFunctions _functions() =>
      FirebaseFunctions.instanceFor(region: _region);

  /// Extends (or starts) featuring by [durationDays] days.
  static Future<DateTime> featureProperty({
    required String propertyId,
    required int durationDays,
  }) async {
    final callable = _functions().httpsCallable(_callableName);
    final res = await callable.call<Map<String, dynamic>>({
      'propertyId': propertyId,
      'durationDays': durationDays,
    });
    final data = Map<String, dynamic>.from(res.data);
    final ms = data['newFeaturedUntilMs'];
    if (ms is int) {
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final iso = data['newFeaturedUntil']?.toString();
    if (iso is String && iso.isNotEmpty) {
      return DateTime.parse(iso);
    }
    throw FirebaseFunctionsException(
      code: 'internal',
      message: 'featureProperty returned invalid payload',
    );
  }

  /// Paid featuring: logs payment server-side, then extends featuring.
  static Future<DateTime> featurePropertyPaid({
    required String propertyId,
    required int durationDays,
    required double amountKwd,
    required String paymentId,
    String gateway = 'MyFatoorah',
  }) async {
    // Dev/profile: use mock function (no secrets / no gateway).
    // Release: use production verified function.
    final callableName = kReleaseMode ? _callablePaidName : _callableMockName;
    final callable = _functions().httpsCallable(callableName);
    final res = await callable.call<Map<String, dynamic>>({
      'propertyId': propertyId,
      'durationDays': durationDays,
      'amountKwd': amountKwd,
      'paymentId': paymentId,
      'gateway': gateway,
    });
    final data = Map<String, dynamic>.from(res.data);
    final ms = data['newFeaturedUntilMs'];
    if (ms is int) {
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final iso = data['newFeaturedUntil']?.toString();
    if (iso is String && iso.isNotEmpty) {
      return DateTime.parse(iso);
    }
    throw FirebaseFunctionsException(
      code: 'internal',
      message: 'featurePropertyPaid returned invalid payload',
    );
  }
}

