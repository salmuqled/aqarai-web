// lib/models/chalet_booking.dart
//
// Read model for `bookings/{id}`. Legacy documents may omit [pricePerNight], [currency], [confirmedAt], [bookingVersion].

import 'package:cloud_firestore/cloud_firestore.dart';

/// One busy stay interval for chalet calendar UI (bookings + blocks).
class ChaletBookedRange {
  const ChaletBookedRange({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

/// Nullable [pricePerNight] / [currency] / [confirmedAt] for backward compatibility.
class ChaletBooking {
  const ChaletBooking({
    required this.id,
    required this.propertyId,
    required this.ownerId,
    required this.clientId,
    required this.startDate,
    required this.endDate,
    required this.status,
    this.pricePerNight,
    this.currency,
    required this.totalPrice,
    required this.daysCount,
    this.createdAt,
    this.confirmedAt,
    this.bookingVersion,
  });

  final String id;
  final String propertyId;
  final String ownerId;
  final String clientId;
  final DateTime startDate;
  final DateTime endDate;
  final String status;

  /// Frozen nightly rate at booking time; may be null on legacy rows.
  final double? pricePerNight;

  /// ISO-like currency code from Firestore; null/empty → use [effectiveCurrency].
  final String? currency;

  final double totalPrice;
  final int daysCount;

  final DateTime? createdAt;

  /// Server-set when host/admin confirms; null while pending or on legacy confirms.
  final DateTime? confirmedAt;

  /// Optional server marker on newer booking docs; null on legacy rows.
  final int? bookingVersion;

  /// Display/default currency when [currency] is missing (legacy documents).
  String get effectiveCurrency {
    final c = currency?.trim();
    if (c == null || c.isEmpty) return 'KWD';
    return c;
  }

  static DateTime? _timestampToDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }

  static double? _optionalDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static String? _optionalCurrency(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return s;
  }

  static double _requiredDouble(dynamic v, double fallback) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  static int _requiredInt(dynamic v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static int? _optionalInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// Lenient parse for production reads (missing fields use safe fallbacks where required by type).
  factory ChaletBooking.fromFirestore(
    String id,
    Map<String, dynamic> data,
  ) {
    final start = _timestampToDate(data['startDate']);
    final end = _timestampToDate(data['endDate']);
    return ChaletBooking(
      id: id,
      propertyId: data['propertyId']?.toString() ?? '',
      ownerId: data['ownerId']?.toString() ?? '',
      clientId: data['clientId']?.toString() ?? '',
      startDate: start ?? DateTime.fromMillisecondsSinceEpoch(0),
      endDate: end ?? DateTime.fromMillisecondsSinceEpoch(0),
      status: data['status']?.toString() ?? '',
      pricePerNight: _optionalDouble(data['pricePerNight']),
      currency: _optionalCurrency(data['currency']),
      totalPrice: _requiredDouble(data['totalPrice'], 0),
      daysCount: _requiredInt(data['daysCount'], 0),
      createdAt: _timestampToDate(data['createdAt']),
      confirmedAt: _timestampToDate(data['confirmedAt']),
      bookingVersion: _optionalInt(data['bookingVersion']),
    );
  }
}
