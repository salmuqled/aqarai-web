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
//   "status": "pending_payment",
//   "pricePerNight": 100.0,
//   "currency": "KWD",
//   "totalPrice": 300.0,
//   "daysCount": 3,
//   "createdAt": "Timestamp",
//   "expiresAt": "Timestamp (pending_payment payment window)",
//   "confirmedAt": null until confirm
// }
// ```

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:aqarai_app/config/chalet_booking_payment_mode.dart';
import 'package:aqarai_app/models/chalet_booking.dart';

/// Known `reason` strings from `checkBookingAvailability` (extend-only; unknown values are kept as [ChaletBookingAvailabilityResult.reason] for forward compatibility).
abstract final class ChaletBookingAvailabilityReason {
  ChaletBookingAvailabilityReason._();

  static const invalidDates = 'invalid_dates';
  static const overlap = 'overlap';
  static const notBookable = 'not_bookable';
  static const notDailyChalet = 'not_daily_chalet';

  static const apartmentDailyAccessIncomplete =
      'apartment_daily_access_incomplete';

  static const Set<String> known = {
    invalidDates,
    overlap,
    notBookable,
    notDailyChalet,
    apartmentDailyAccessIncomplete,
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

/// Result of [ChaletBookingService.createBooking] and other booking callables.
///
/// [totalPrice], [daysCount], and [pricePerNight] are set only when the server
/// returns them (e.g. [createBooking] success).
class ChaletBookingResult {
  const ChaletBookingResult._({
    required this.ok,
    this.bookingId,
    this.errorMessage,
    this.totalPrice,
    this.daysCount,
    this.pricePerNight,
  });

  final bool ok;
  final String? bookingId;
  final String? errorMessage;
  final double? totalPrice;
  final int? daysCount;
  final double? pricePerNight;

  factory ChaletBookingResult.success(String bookingId) =>
      ChaletBookingResult._(ok: true, bookingId: bookingId);

  factory ChaletBookingResult.createSuccess({
    required String bookingId,
    required double totalPrice,
    required int daysCount,
    required double pricePerNight,
  }) =>
      ChaletBookingResult._(
        ok: true,
        bookingId: bookingId,
        totalPrice: totalPrice,
        daysCount: daysCount,
        pricePerNight: pricePerNight,
      );

  factory ChaletBookingResult.failure(String message) =>
      ChaletBookingResult._(ok: false, errorMessage: message);
}

/// MyFatoorah payment session for a `pending_payment` booking (server creates invoice URL).
class ChaletBookingPaymentSessionResult {
  const ChaletBookingPaymentSessionResult._({
    required this.ok,
    this.paymentUrl,
    this.paymentId,
    this.invoiceId,
    this.errorMessage,
  });

  final bool ok;
  final String? paymentUrl;
  final String? paymentId;
  final String? invoiceId;
  final String? errorMessage;

  factory ChaletBookingPaymentSessionResult.success({
    required String paymentUrl,
    required String paymentId,
    String? invoiceId,
  }) =>
      ChaletBookingPaymentSessionResult._(
        ok: true,
        paymentUrl: paymentUrl,
        paymentId: paymentId,
        invoiceId: invoiceId,
      );

  factory ChaletBookingPaymentSessionResult.failure(String message) =>
      ChaletBookingPaymentSessionResult._(ok: false, errorMessage: message);
}

/// Outcome of [ChaletBookingService.submitChaletBookingConfirmationPayment].
enum ChaletBookingPayNowStatus {
  fakeSucceeded,
  myfatoorahSessionStarted,
  failed,
}

/// Single entry point for "Pay now" on [BookingConfirmationPage].
class ChaletBookingConfirmationPayResult {
  const ChaletBookingConfirmationPayResult._({
    required this.status,
    required this.mode,
    this.errorMessage,
    this.paymentUrl,
    this.paymentId,
    this.invoiceId,
  });

  final ChaletBookingPayNowStatus status;
  final PaymentMode mode;
  final String? errorMessage;
  final String? paymentUrl;
  final String? paymentId;
  final String? invoiceId;
}

/// Reads/callables for chalet reservations (Firestore rules block direct writes).
/// Snapshot of a single property's busy ranges plus the wall-clock time
/// they were fetched, used by [ChaletBookingService]'s in-memory TTL
/// cache. Internal — kept private to the service file.
///
/// The monotonically increasing [version] lets callers / tests tell a
/// fresh entry apart from a TTL-refreshed one even if the contents are
/// identical (e.g. no new bookings arrived between polls).
class _CachedBusyRanges {
  const _CachedBusyRanges({
    required this.ranges,
    required this.fetchedAt,
    required this.version,
  });
  final List<ChaletBookedRange> ranges;
  final DateTime fetchedAt;
  final int version;
}

abstract final class ChaletBookingService {
  ChaletBookingService._();

  static FirebaseFunctions _functions() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Strict availability check before creating a booking.
  ///
  /// Checks:
  /// - Server callable `checkBookingAvailability` (authoritative for `bookings` overlap + bookability).
  /// - Firestore `blocked_dates` overlap (external/manual blocks, no commission).
  ///
  /// Returns `true` only when both checks indicate availability.
  static Future<bool> checkDateAvailability({
    required String propertyId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    // 1) Server check (bookings + bookability)
    final r = await checkBookingAvailability(
      propertyId: propertyId,
      startDate: startDate,
      endDate: endDate,
    );
    if (r == null) return false; // strict: unknown => block
    if (!r.available) return false;

    // 2) External blocks (`blocked_dates`)
    try {
      final db = FirebaseFirestore.instance;
      final reqStart = Timestamp.fromDate(startDate);
      final reqEnd = Timestamp.fromDate(endDate);

      // Fetch candidate blocks that start before (or on) the requested end.
      // We filter final overlap in-memory using:
      // (start <= existingEnd) && (end >= existingStart)
      final snap = await db
          .collection('blocked_dates')
          .where('propertyId', isEqualTo: propertyId)
          .where('startDate', isLessThanOrEqualTo: reqEnd)
          .get();

      bool overlaps(Timestamp aStart, Timestamp aEnd) {
        return reqStart.compareTo(aEnd) <= 0 && reqEnd.compareTo(aStart) >= 0;
      }

      for (final d in snap.docs) {
        final m = d.data();
        final s = m['startDate'];
        final e = m['endDate'];
        if (s is! Timestamp || e is! Timestamp) continue;
        if (overlaps(s, e)) return false;
      }
      return true;
    } catch (_) {
      return false; // strict: error => block
    }
  }

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
        final tpRaw = data['totalPrice'];
        final dcRaw = data['daysCount'];
        final ppnRaw = data['pricePerNight'];
        final totalPrice = tpRaw is num
            ? tpRaw.toDouble()
            : double.tryParse(tpRaw?.toString() ?? '');
        final daysCount = dcRaw is num
            ? dcRaw.toInt()
            : int.tryParse(dcRaw?.toString() ?? '');
        final pricePerNight = ppnRaw is num
            ? ppnRaw.toDouble()
            : double.tryParse(ppnRaw?.toString() ?? '');
        if (totalPrice == null ||
            !totalPrice.isFinite ||
            totalPrice <= 0 ||
            daysCount == null ||
            daysCount < 1 ||
            pricePerNight == null ||
            !pricePerNight.isFinite) {
          return ChaletBookingResult.failure('Invalid server response');
        }
        return ChaletBookingResult.createSuccess(
          bookingId: id,
          totalPrice: totalPrice,
          daysCount: daysCount,
          pricePerNight: pricePerNight,
        );
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

  /// In-memory TTL cache for [getChaletBusyDateRanges]. Keyed by
  /// `propertyId` and refreshed on demand. The cache lets repeated visits
  /// to the same chalet (in the same session) skip the Cloud Function
  /// round-trip when the data is still fresh, without compromising the
  /// 45-second background refresh in `_ChaletBookingFirestoreGate`
  /// (which calls with `forceRefresh: true`).
  ///
  /// Uses a `LinkedHashMap` so iteration order reflects insertion order —
  /// this lets [_storeInCache] implement cheap FIFO-LRU eviction once
  /// [_maxBusyCacheEntries] is exceeded (we evict the oldest entry).
  ///
  /// Visible for testing only. Do not mutate from production code.
  static final Map<String, _CachedBusyRanges> _busyRangesCache =
      <String, _CachedBusyRanges>{};

  /// How long a cached busy-ranges payload is considered fresh.
  static const Duration _busyRangesTtl = Duration(minutes: 5);

  /// Upper bound on cached properties. Prevents unbounded growth if a
  /// session browses many chalets in sequence. Cheap bound — each entry
  /// is a short list of date pairs, but we still cap it.
  static const int _maxBusyCacheEntries = 50;

  /// Process-wide monotonic version counter. Incremented on every
  /// successful cache write so callers (and tests) can detect a
  /// refresh even when the payload is byte-identical.
  static int _busyRangesVersionCounter = 0;

  /// Clears the in-memory busy-ranges cache. Used by tests and by callers
  /// that know external state has changed (e.g. after a successful
  /// booking).
  static void invalidateBusyRangesCache({String? propertyId}) {
    if (propertyId == null) {
      _busyRangesCache.clear();
    } else {
      _busyRangesCache.remove(propertyId);
    }
  }

  /// Writes [ranges] for [propertyId] into the cache, bumping the global
  /// [_busyRangesVersionCounter] and evicting the oldest entry when the
  /// map grows past [_maxBusyCacheEntries].
  static _CachedBusyRanges _storeInCache(
    String propertyId,
    List<ChaletBookedRange> ranges,
  ) {
    _busyRangesVersionCounter++;
    final entry = _CachedBusyRanges(
      ranges: List<ChaletBookedRange>.unmodifiable(ranges),
      fetchedAt: DateTime.now(),
      version: _busyRangesVersionCounter,
    );
    _busyRangesCache[propertyId] = entry;
    while (_busyRangesCache.length > _maxBusyCacheEntries) {
      // `Map.keys` preserves insertion order for the default map impl
      // used by the Dart VM, so `.first` is always the oldest entry.
      final oldest = _busyRangesCache.keys.first;
      _busyRangesCache.remove(oldest);
    }
    return entry;
  }

  /// Server-only busy intervals from `bookings` (milliseconds, no PII). Merge with Firestore `blocked_dates` in the client.
  /// Returns null on failure; on repeated failures callers may keep the last successful list.
  ///
  /// Set [forceRefresh] to bypass the in-memory TTL cache (used by the
  /// background poller). Successful network responses always update the
  /// cache so a subsequent fast read is served instantly.
  static Future<List<ChaletBookedRange>?> getChaletBusyDateRanges({
    required String propertyId,
    bool forceRefresh = false,
  }) async {
    final cachedAtCallTime = _busyRangesCache[propertyId];
    if (!forceRefresh && cachedAtCallTime != null) {
      final age = DateTime.now().difference(cachedAtCallTime.fetchedAt);
      if (age < _busyRangesTtl) return cachedAtCallTime.ranges;
    }
    try {
      final callable = _functions().httpsCallable('getChaletBusyDateRanges');
      final res = await callable.call<dynamic>({
        'propertyId': propertyId,
      });
      final raw = res.data;
      if (raw is! Map) {
        // Server answered but with a payload we can't parse — prefer a
        // stale-but-correct answer (if any) over returning null to the
        // UI, which would otherwise look like a full reload.
        return cachedAtCallTime?.ranges;
      }
      final list = raw['ranges'];
      if (list is! List) return cachedAtCallTime?.ranges;
      final out = <ChaletBookedRange>[];
      for (final item in list) {
        if (item is! Map) continue;
        final sm = item['startMs'];
        final em = item['endMs'];
        if (sm is! num || em is! num) continue;
        final start = DateTime.fromMillisecondsSinceEpoch(
          sm.toInt(),
          isUtc: true,
        ).toLocal();
        final end = DateTime.fromMillisecondsSinceEpoch(
          em.toInt(),
          isUtc: true,
        ).toLocal();
        out.add(ChaletBookedRange(start: start, end: end));
      }
      final stored = _storeInCache(propertyId, out);
      return stored.ranges;
    } on FirebaseFunctionsException {
      // Network / server error: fall back to the last known good data
      // for this property if we have any, so the UI keeps working
      // offline and mid-glitch. The background poller will retry.
      return cachedAtCallTime?.ranges;
    } catch (_) {
      return cachedAtCallTime?.ranges;
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

  /// Server: InitiatePayment + ExecutePayment → payment URL for this booking.
  static Future<ChaletBookingPaymentSessionResult> createBookingMyFatoorahPayment({
    required String bookingId,
    required String lang,
  }) async {
    try {
      final callable = _functions().httpsCallable('createBookingMyFatoorahPayment');
      final res = await callable.call<dynamic>({
        'bookingId': bookingId,
        'lang': lang,
      });
      final raw = res.data;
      if (raw is! Map) {
        return ChaletBookingPaymentSessionResult.failure('Invalid server response');
      }
      final data = Map<String, dynamic>.from(raw);
      if (data['ok'] == true) {
        final url = data['paymentUrl']?.toString().trim() ?? '';
        final pid = data['paymentId']?.toString().trim() ?? '';
        if (url.isEmpty || pid.isEmpty) {
          return ChaletBookingPaymentSessionResult.failure('Missing payment session');
        }
        final inv = data['invoiceId']?.toString().trim();
        return ChaletBookingPaymentSessionResult.success(
          paymentUrl: url,
          paymentId: pid,
          invoiceId: inv != null && inv.isNotEmpty ? inv : null,
        );
      }
      return ChaletBookingPaymentSessionResult.failure(
        data['message']?.toString() ?? 'Payment session failed',
      );
    } on FirebaseFunctionsException catch (e) {
      return ChaletBookingPaymentSessionResult.failure(e.message ?? e.code);
    } catch (e) {
      return ChaletBookingPaymentSessionResult.failure(e.toString());
    }
  }

  /// Server: GetPaymentStatus → only if paid, sets booking to `confirmed`.
  static Future<ChaletBookingResult> verifyBookingMyFatoorahPayment({
    required String bookingId,
    required String paymentId,
  }) async {
    try {
      final callable = _functions().httpsCallable('verifyBookingMyFatoorahPayment');
      final res = await callable.call<dynamic>({
        'bookingId': bookingId,
        'paymentId': paymentId,
      });
      final raw = res.data;
      if (raw is! Map) {
        return ChaletBookingResult.failure('Invalid server response');
      }
      if (Map<String, dynamic>.from(raw)['ok'] == true) {
        return ChaletBookingResult.success(bookingId);
      }
      return ChaletBookingResult.failure('Verify failed');
    } on FirebaseFunctionsException catch (e) {
      return ChaletBookingResult.failure(e.message ?? e.code);
    } catch (e) {
      return ChaletBookingResult.failure(e.toString());
    }
  }

  /// DEV/QA: server confirms `pending_payment` as `confirmed` when fake payment is enabled
  /// (`ALLOW_CHALET_FAKE_PAYMENT=true`). Does not call MyFatoorah.
  static Future<ChaletBookingResult> simulateChaletBookingPayment({
    required String bookingId,
  }) async {
    try {
      final callable = _functions().httpsCallable('simulateChaletBookingPayment');
      final res = await callable.call<dynamic>({'bookingId': bookingId});
      final raw = res.data;
      if (raw is! Map) {
        return ChaletBookingResult.failure('Invalid server response');
      }
      if (Map<String, dynamic>.from(raw)['ok'] == true) {
        return ChaletBookingResult.success(bookingId);
      }
      return ChaletBookingResult.failure('Simulate confirm failed');
    } on FirebaseFunctionsException catch (e) {
      return ChaletBookingResult.failure(e.message ?? e.code);
    } catch (e) {
      return ChaletBookingResult.failure(e.toString());
    }
  }

  /// DEV/QA: marks `pending_payment` as paid+confirmed and writes ledger rows (fake gateway).
  ///
  /// Requires Functions runtime: `ALLOW_CHALET_FAKE_PAYMENT=true`.
  static Future<({bool ok, String? paymentId, String? errorMessage})> fakePayChaletBooking({
    required String bookingId,
  }) async {
    try {
      final callable = _functions().httpsCallable('fakePayChaletBooking');
      final res = await callable.call<dynamic>({'bookingId': bookingId});
      final raw = res.data;
      if (raw is! Map) {
        return (ok: false, paymentId: null, errorMessage: 'Invalid server response');
      }
      final data = Map<String, dynamic>.from(raw);
      if (data['ok'] == true) {
        final pid = data['paymentId']?.toString().trim();
        return (ok: true, paymentId: (pid == null || pid.isEmpty) ? null : pid, errorMessage: null);
      }
      return (
        ok: false,
        paymentId: null,
        errorMessage: data['message']?.toString() ?? 'Fake payment failed',
      );
    } on FirebaseFunctionsException catch (e) {
      return (ok: false, paymentId: null, errorMessage: e.message ?? e.code);
    } catch (e) {
      return (ok: false, paymentId: null, errorMessage: e.toString());
    }
  }

  /// Confirmation screen: routes to fake pay or MyFatoorah session creation per [getPaymentMode].
  ///
  /// Does not open a WebView; MyFatoorah path only calls [createBookingMyFatoorahPayment].
  static Future<ChaletBookingConfirmationPayResult>
      submitChaletBookingConfirmationPayment({
    required String bookingId,
    required String lang,
  }) async {
    final mode = getPaymentMode();
    logChaletPaymentMode(mode);

    switch (mode) {
      case PaymentMode.fake:
        final r = await fakePayChaletBooking(bookingId: bookingId);
        if (r.ok) {
          return ChaletBookingConfirmationPayResult._(
            status: ChaletBookingPayNowStatus.fakeSucceeded,
            mode: mode,
          );
        }
        return ChaletBookingConfirmationPayResult._(
          status: ChaletBookingPayNowStatus.failed,
          mode: mode,
          errorMessage:
              r.errorMessage ?? 'Fake payment failed',
        );
      case PaymentMode.myfatoorah:
        final session = await createBookingMyFatoorahPayment(
          bookingId: bookingId,
          lang: lang,
        );
        if (session.ok) {
          debugPrint(
            'MYFATOORAH_SESSION_READY bookingId=$bookingId '
            'paymentId=${session.paymentId}',
          );
          return ChaletBookingConfirmationPayResult._(
            status: ChaletBookingPayNowStatus.myfatoorahSessionStarted,
            mode: mode,
            paymentUrl: session.paymentUrl,
            paymentId: session.paymentId,
            invoiceId: session.invoiceId,
          );
        }
        return ChaletBookingConfirmationPayResult._(
          status: ChaletBookingPayNowStatus.failed,
          mode: mode,
          errorMessage:
              session.errorMessage ?? 'Payment session failed',
        );
    }
  }

  /// Server: sets `cancelled` when booking is still `pending_payment`.
  static Future<ChaletBookingResult> cancelBookingPendingPayment({
    required String bookingId,
  }) async {
    try {
      final callable = _functions().httpsCallable('cancelBookingPendingPayment');
      final res = await callable.call<dynamic>({'bookingId': bookingId});
      final raw = res.data;
      if (raw is! Map) {
        return ChaletBookingResult.failure('Invalid server response');
      }
      if (Map<String, dynamic>.from(raw)['ok'] == true) {
        return ChaletBookingResult.success(bookingId);
      }
      return ChaletBookingResult.failure('Cancel failed');
    } on FirebaseFunctionsException catch (e) {
      return ChaletBookingResult.failure(e.message ?? e.code);
    } catch (e) {
      return ChaletBookingResult.failure(e.toString());
    }
  }
}
