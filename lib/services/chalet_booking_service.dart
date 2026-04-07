// lib/services/chalet_booking_service.dart
//
// Chalet bookings: writes via Cloud Functions ([createBooking], [confirmBooking], [rejectBooking]).
// Overlap against **confirmed** bookings only is enforced on the server
// (rule: (startA < endB) && (endA > startB)).
//
// Example `bookings/{id}` document (created by function; clients cannot write):
// ```json
// {
//   "propertyId": "Qm9ExamplePropertyId",
//   "ownerId": "ownerFirebaseUid",
//   "clientId": "clientFirebaseUid",
//   "startDate": "Timestamp",
//   "endDate": "Timestamp",
//   "status": "pending",
//   "pricePerNight": 100.0,
//   "currency": "KWD",
//   "totalPrice": 300.0,
//   "daysCount": 3,
//   "createdAt": "Timestamp",
//   "confirmedAt": null until confirm
// }
// ```

import 'package:cloud_functions/cloud_functions.dart';

/// Known `reason` strings from `checkBookingAvailability` (extend-only; unknown values are kept as [ChaletBookingAvailabilityResult.reason] for forward compatibility).
abstract final class ChaletBookingAvailabilityReason {
  ChaletBookingAvailabilityReason._();

  static const invalidDates = 'invalid_dates';
  static const overlap = 'overlap';
  static const notBookable = 'not_bookable';
  static const notDailyChalet = 'not_daily_chalet';

  static const Set<String> known = {
    invalidDates,
    overlap,
    notBookable,
    notDailyChalet,
  };
}

/// Response from [ChaletBookingService.checkBookingAvailability] (callable `checkBookingAvailability`).
class ChaletBookingAvailabilityResult {
  const ChaletBookingAvailabilityResult({
    required this.available,
    this.reason,
  });

  final bool available;

  /// Server `reason` when [available] is false; null when available or omitted.
  /// Treat unrecognized strings as generic "blocked" in UI — see [reasonIsKnown].
  final String? reason;

  bool get reasonIsKnown =>
      reason != null &&
      ChaletBookingAvailabilityReason.known.contains(reason);

  factory ChaletBookingAvailabilityResult.fromResponse(Map<String, dynamic> raw) {
    final available = raw['available'] == true;
    if (available) {
      return const ChaletBookingAvailabilityResult(available: true);
    }
    final r = raw['reason']?.toString().trim();
    return ChaletBookingAvailabilityResult(
      available: false,
      reason: r == null || r.isEmpty ? null : r,
    );
  }
}

/// Result of [ChaletBookingService.createBooking].
class ChaletBookingResult {
  const ChaletBookingResult._({
    required this.ok,
    this.bookingId,
    this.errorMessage,
  });

  final bool ok;
  final String? bookingId;
  final String? errorMessage;

  factory ChaletBookingResult.success(String bookingId) =>
      ChaletBookingResult._(ok: true, bookingId: bookingId);

  factory ChaletBookingResult.failure(String message) =>
      ChaletBookingResult._(ok: false, errorMessage: message);
}

/// Reads/callables for chalet reservations (Firestore rules block direct writes).
abstract final class ChaletBookingService {
  ChaletBookingService._();

  static FirebaseFunctions _functions() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Authoritative create. Server runs overlap check inside a transaction
  /// against bookings with `status == "confirmed"` only.
  static Future<ChaletBookingResult> createBooking({
    required String propertyId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final callable = _functions().httpsCallable('createBooking');
      final res = await callable.call<dynamic>({
        'propertyId': propertyId,
        'startDate': startDate.toUtc().toIso8601String(),
        'endDate': endDate.toUtc().toIso8601String(),
      });
      final raw = res.data;
      if (raw is! Map) {
        return ChaletBookingResult.failure('Invalid server response');
      }
      final data = Map<String, dynamic>.from(raw);
      if (data['ok'] == true) {
        final id = data['bookingId']?.toString() ?? '';
        if (id.isEmpty) {
          return ChaletBookingResult.failure('Missing booking id');
        }
        return ChaletBookingResult.success(id);
      }
      return ChaletBookingResult.failure(
        data['message']?.toString() ?? 'Booking failed',
      );
    } on FirebaseFunctionsException catch (e) {
      return ChaletBookingResult.failure(e.message ?? e.code);
    } catch (e) {
      return ChaletBookingResult.failure(e.toString());
    }
  }

  /// Pre-validation only; [createBooking] always decides. Do not treat as a guarantee.
  ///
  /// On success, returns structured [ChaletBookingAvailabilityResult] (includes optional [ChaletBookingAvailabilityResult.reason]).
  /// Returns null only when the callable fails (e.g. network) or the payload is not a map.
  static Future<ChaletBookingAvailabilityResult?> checkBookingAvailability({
    required String propertyId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    try {
      final callable = _functions().httpsCallable('checkBookingAvailability');
      final res = await callable.call<dynamic>({
        'propertyId': propertyId,
        'startDate': startDate.toUtc().toIso8601String(),
        'endDate': endDate.toUtc().toIso8601String(),
      });
      final raw = res.data;
      if (raw is! Map) return null;
      return ChaletBookingAvailabilityResult.fromResponse(
        Map<String, dynamic>.from(raw),
      );
    } on FirebaseFunctionsException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Same as [checkBookingAvailability] but yields only whether the range is available (`true` / `false`).
  ///
  /// Returns null when the request fails so callers can distinguish "unknown" from "unavailable".
  static Future<bool?> checkAvailability({
    required String propertyId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final r = await checkBookingAvailability(
      propertyId: propertyId,
      startDate: startDate,
      endDate: endDate,
    );
    if (r == null) return null;
    return r.available;
  }

  /// Host or admin: confirms pending booking after server-side overlap check vs confirmed only.
  static Future<ChaletBookingResult> confirmBooking({
    required String bookingId,
  }) async {
    try {
      final callable = _functions().httpsCallable('confirmBooking');
      final res = await callable.call<dynamic>({'bookingId': bookingId});
      final raw = res.data;
      if (raw is! Map) {
        return ChaletBookingResult.failure('Invalid server response');
      }
      if (Map<String, dynamic>.from(raw)['ok'] == true) {
        return ChaletBookingResult.success(bookingId);
      }
      return ChaletBookingResult.failure('Confirm failed');
    } on FirebaseFunctionsException catch (e) {
      return ChaletBookingResult.failure(e.message ?? e.code);
    } catch (e) {
      return ChaletBookingResult.failure(e.toString());
    }
  }

  /// Owner, guest (pending), or admin: sets status to cancelled.
  static Future<ChaletBookingResult> rejectBooking({
    required String bookingId,
  }) async {
    try {
      final callable = _functions().httpsCallable('rejectBooking');
      final res = await callable.call<dynamic>({'bookingId': bookingId});
      final raw = res.data;
      if (raw is! Map) {
        return ChaletBookingResult.failure('Invalid server response');
      }
      if (Map<String, dynamic>.from(raw)['ok'] == true) {
        return ChaletBookingResult.success(bookingId);
      }
      return ChaletBookingResult.failure('Reject failed');
    } on FirebaseFunctionsException catch (e) {
      return ChaletBookingResult.failure(e.message ?? e.code);
    } catch (e) {
      return ChaletBookingResult.failure(e.toString());
    }
  }
}
