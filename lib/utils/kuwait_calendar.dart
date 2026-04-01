import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

/// Kuwait Standard Time (**UTC+3**, no DST).
///
/// ### Firestore (filtering)
/// Range queries use **UTC instants** only: build bounds with
/// [utcInstantStartOfKuwaitDay] and pass them to [Timestamp.fromDate]. Stored
/// document fields are compared as UTC; the device timezone is never used for
/// those bounds.
///
/// ### Grouping & UI labels
/// After reading a [Timestamp], convert with [utcInstantFromFirestore] then
/// derive the Kuwait **civil calendar** date with [kuwaitDateOnlyFromUtcInstant]
/// (or [kuwaitDateOnlyFromTimestamp]). Chart buckets and “today” in Kuwait
/// follow that calendar, not [DateTime.now()] in local time.
///
/// Example:
/// ```dart
/// final ts = data['auctionFeePaidAt'] as Timestamp;
/// final utc = KuwaitCalendar.utcInstantFromFirestore(ts);
/// final kuwaitDay = KuwaitCalendar.kuwaitDateOnlyFromUtcInstant(utc);
/// // kuwaitDay is DateTime.utc(y, m, d) — label key, not a zone-specific instant
///
/// final start = KuwaitCalendar.utcInstantStartOfKuwaitDay(kuwaitDay);
/// final query = col.where('auctionFeePaidAt',
///     isGreaterThanOrEqualTo: Timestamp.fromDate(start));
/// ```
abstract final class KuwaitCalendar {
  KuwaitCalendar._();

  static const Duration utcOffset = Duration(hours: 3);

  /// Absolute instant from Firestore (epoch → UTC; ignores device timezone).
  static DateTime utcInstantFromFirestore(Timestamp ts) {
    final ms = ts.seconds * 1000 + ts.nanoseconds ~/ 1000000;
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// Kuwait civil date for this UTC instant, as `DateTime.utc(y, m, d)`.
  static DateTime kuwaitDateOnlyFromUtcInstant(DateTime utcInstant) {
    assert(utcInstant.isUtc);
    final shifted = utcInstant.add(utcOffset);
    return DateTime.utc(shifted.year, shifted.month, shifted.day);
  }

  static DateTime kuwaitDateOnlyFromTimestamp(Timestamp ts) =>
      kuwaitDateOnlyFromUtcInstant(utcInstantFromFirestore(ts));

  /// Kuwait “today” (civil) from the current instant; uses **UTC now** + offset
  /// so the calendar date does not depend on the device’s local timezone.
  static DateTime kuwaitTodayDateOnly() {
    final shifted = DateTime.now().toUtc().add(utcOffset);
    return DateTime.utc(shifted.year, shifted.month, shifted.day);
  }

  /// UTC instant at **Kuwait midnight** starting [kuwaitDate].
  ///
  /// [kuwaitDate] must be `DateTime.utc(year, month, day)` from Kuwait calendar.
  /// Use the result with [Timestamp.fromDate] for `>=` query lower bounds.
  static DateTime utcInstantStartOfKuwaitDay(DateTime kuwaitDate) {
    assert(kuwaitDate.isUtc);
    return DateTime.utc(
      kuwaitDate.year,
      kuwaitDate.month,
      kuwaitDate.day,
    ).subtract(utcOffset);
  }

  /// [Timestamp] for a UTC instant (explicit helper next to query code).
  static Timestamp timestampFromUtcInstant(DateTime utcInstant) {
    assert(utcInstant.isUtc);
    return Timestamp.fromDate(utcInstant);
  }

  /// Short label for a Kuwait `dayKey` (`yyyy-MM-dd`); uses UTC noon so
  /// [DateFormat] cannot shift the civil day on extreme device timezones.
  static String formatDayKeyMedium(String dayKey, String locale) {
    final parts = dayKey.split('-');
    if (parts.length != 3) return dayKey;
    try {
      final y = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final d = int.parse(parts[2]);
      return DateFormat.MMMd(locale).format(DateTime.utc(y, m, d, 12));
    } catch (_) {
      return dayKey;
    }
  }
}
