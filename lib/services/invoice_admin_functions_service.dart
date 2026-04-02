import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:http/http.dart' as http;

/// Admin HTTPS callables for invoice operations (region matches Cloud Functions).
abstract final class InvoiceAdminFunctionsService {
  InvoiceAdminFunctionsService._();

  static const String _region = 'us-central1';

  static FirebaseFunctions _f() =>
      FirebaseFunctions.instanceFor(region: _region);

  /// Serialize server work so two taps cannot enqueue duplicate business logic.
  static Future<void> _recreateQueueTail = Future.value();

  static Future<Map<String, dynamic>> resendInvoiceEmail(String invoiceId) async {
    final callable = _f().httpsCallable('resendInvoiceEmail');
    final result = await callable.call(<String, dynamic>{'invoiceId': invoiceId});
    final raw = result.data;
    if (raw == null) return {};
    return Map<String, dynamic>.from(raw as Map);
  }

  static Future<Map<String, dynamic>> retryInvoicePdf(String invoiceId) async {
    final callable = _f().httpsCallable('retryInvoicePdf');
    final result = await callable.call(<String, dynamic>{'invoiceId': invoiceId});
    final raw = result.data;
    if (raw == null) return {};
    return Map<String, dynamic>.from(raw as Map);
  }

  /// Cancels non-cancelled invoices for [paymentId], creates a new invoice, PDF+email;
  /// does not duplicate `financial_ledger` when a row already exists for the payment.
  ///
  /// On **iOS/Android**, uses raw HTTPS + ID token instead of the platform-channel
  /// callable, to avoid `GTMSessionFetcher was already running` when the native
  /// layer reuses a fetcher. **Web** keeps [HttpsCallable] (CORS / same browser stack).
  static Future<Map<String, dynamic>> recreateInvoiceForPayment(
    String paymentId,
  ) {
    final completer = Completer<Map<String, dynamic>>();
    _recreateQueueTail = _recreateQueueTail.then((_) async {
      try {
        final map = kIsWeb
            ? await _recreateInvoiceViaCallable(paymentId)
            : await _recreateInvoiceViaHttpWithRetry(paymentId);
        if (!completer.isCompleted) completer.complete(map);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static Future<Map<String, dynamic>> _recreateInvoiceViaCallable(
    String paymentId,
  ) async {
    final callable = _f().httpsCallable('recreateInvoiceForPayment');
    final result = await callable.call(<String, dynamic>{
      'paymentId': paymentId,
    });
    final raw = result.data;
    if (raw == null) return {};
    return Map<String, dynamic>.from(raw as Map);
  }

  /// One slow retry helps when iOS briefly reports no route (IPv6 / radio wake).
  static Future<Map<String, dynamic>> _recreateInvoiceViaHttpWithRetry(
    String paymentId,
  ) async {
    try {
      try {
        return await _recreateInvoiceViaHttpOnce(paymentId);
      } on FirebaseFunctionsException catch (e) {
        if (e.code.toLowerCase() == 'unavailable' ||
            e.code.toLowerCase() == 'deadline-exceeded') {
          if (kDebugMode) {
            debugPrint(
              '[invoice_recreate] RETRY in 1s (${e.code}): ${e.message}',
            );
          }
          await Future<void>.delayed(const Duration(seconds: 1));
          return _recreateInvoiceViaHttpOnce(paymentId);
        }
        rethrow;
      } catch (e) {
        if (_isTransientTransportFailure(e)) {
          if (kDebugMode) {
            debugPrint('[invoice_recreate] RETRY in 1s (transport): $e');
          }
          await Future<void>.delayed(const Duration(seconds: 1));
          return _recreateInvoiceViaHttpOnce(paymentId);
        }
        rethrow;
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[invoice_recreate] FAILED: $e');
        debugPrint('$st');
      }
      rethrow;
    }
  }

  /// Avoid `dart:io` here (web-safe analyzer); name-based checks match SocketException etc.
  static bool _isTransientTransportFailure(Object e) {
    if (e is TimeoutException) return true;
    final t = e.runtimeType.toString();
    if (t == 'SocketException' || t == 'HandshakeException') return true;
    if (t.contains('ClientException')) return true;
    final s = e.toString().toLowerCase();
    return s.contains('failed host lookup') ||
        s.contains('network is unreachable') ||
        s.contains('no route to host') ||
        s.contains('no network route') ||
        s.contains('connection refused') ||
        s.contains('connection reset') ||
        s.contains('network error');
  }

  /// Same wire format as the Firebase client SDK callable HTTP API.
  static Future<Map<String, dynamic>> _recreateInvoiceViaHttpOnce(
    String paymentId,
  ) async {
    if (kDebugMode) {
      debugPrint('[invoice_recreate] START http paymentId=$paymentId');
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw FirebaseFunctionsException(
        code: 'unauthenticated',
        message: 'User must be signed in',
      );
    }

    String token;
    try {
      token = (await user.getIdToken()) ?? '';
    } catch (e) {
      if (_isTransientTransportFailure(e)) {
        throw FirebaseFunctionsException(
          code: 'unavailable',
          message: 'Could not refresh auth token (network).',
        );
      }
      rethrow;
    }
    if (token.isEmpty) {
      throw FirebaseFunctionsException(
        code: 'unauthenticated',
        message: 'Missing ID token',
      );
    }

    final projectId = Firebase.app().options.projectId;
    if (projectId.isEmpty) {
      throw FirebaseFunctionsException(
        code: 'failed-precondition',
        message: 'Firebase projectId is missing',
      );
    }

    final host = '$_region-$projectId.cloudfunctions.net';
    final uri = Uri.https(host, '/recreateInvoiceForPayment');

    if (kDebugMode) {
      debugPrint('[invoice_recreate] POST $uri (region=$_region)');
    }

    late http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{'paymentId': paymentId},
            }),
          )
          .timeout(const Duration(seconds: 130));
    } on TimeoutException {
      throw FirebaseFunctionsException(
        code: 'deadline-exceeded',
        message: 'Request timed out',
      );
    } catch (e) {
      if (_isTransientTransportFailure(e)) {
        throw FirebaseFunctionsException(
          code: 'unavailable',
          message: e.toString(),
        );
      }
      rethrow;
    }

    if (response.statusCode == 404 && !kIsWeb) {
      if (kDebugMode) {
        debugPrint(
          '[invoice_recreate] HTTP 404 — trying httpsCallableFromUrl fallback',
        );
      }
      return _recreateInvoiceViaCallableFromUrl(paymentId);
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw FirebaseFunctionsException(
        code: 'internal',
        message:
            'Invalid response from server (HTTP ${response.statusCode})',
      );
    }

    if (decoded is! Map) {
      throw FirebaseFunctionsException(
        code: 'internal',
        message: 'Unexpected response format',
      );
    }

    final root = Map<String, dynamic>.from(decoded);
    final err = root['error'];
    if (err is Map) {
      final em = Map<String, dynamic>.from(err);
      final msg = em['message'] as String? ?? 'Cloud function error';
      final status = (em['status'] as String? ?? 'internal')
          .toString()
          .toLowerCase()
          .replaceAll('_', '-');
      throw FirebaseFunctionsException(
        code: status,
        message: msg,
        details: em,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FirebaseFunctionsException(
        code: 'internal',
        message: 'HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final result = root['result'];
    if (result == null) {
      if (kDebugMode) {
        debugPrint('[invoice_recreate] END http OK (empty result)');
      }
      return {};
    }
    if (result is Map) {
      final m = Map<String, dynamic>.from(result);
      if (kDebugMode) {
        debugPrint(
          '[invoice_recreate] END http OK status=${response.statusCode} keys=${m.keys.join(",")}',
        );
      }
      return m;
    }
    if (kDebugMode) {
      debugPrint('[invoice_recreate] END http OK (scalar result)');
    }
    return <String, dynamic>{'value': result};
  }

  /// Last resort if the plain callable host returns 404 (unusual Gen2 / URL drift).
  static Future<Map<String, dynamic>> _recreateInvoiceViaCallableFromUrl(
    String paymentId,
  ) async {
    final projectId = Firebase.app().options.projectId;
    final url =
        'https://$_region-$projectId.cloudfunctions.net/recreateInvoiceForPayment';
    final callable = _f().httpsCallableFromUrl(url);
    final result = await callable.call(<String, dynamic>{
      'paymentId': paymentId,
    });
    final raw = result.data;
    if (raw == null) return {};
    return Map<String, dynamic>.from(raw as Map);
  }
}
