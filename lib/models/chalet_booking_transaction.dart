// Read model for `transactions/{id}` (chalet daily booking ledger; id == bookingId for new rows).

import 'package:cloud_firestore/cloud_firestore.dart';

/// Immutable owner fields copied at ledger create (`ownerSnapshot` on newer rows).
class ChaletOwnerSnapshot {
  const ChaletOwnerSnapshot({
    required this.uid,
    required this.name,
    required this.phone,
  });

  final String uid;
  final String name;
  final String phone;

  static ChaletOwnerSnapshot? tryParse(dynamic raw) {
    if (raw == null) return null;
    Map<String, dynamic>? m;
    if (raw is Map<String, dynamic>) {
      m = raw;
    } else if (raw is Map) {
      m = Map<String, dynamic>.from(raw);
    }
    if (m == null || m.isEmpty) return null;
    return ChaletOwnerSnapshot(
      uid: m['uid']?.toString() ?? '',
      name: _trim(m['name']),
      phone: _trim(m['phone']),
    );
  }

  static String _trim(dynamic v) {
    if (v == null) return '';
    return v.toString().trim();
  }
}

/// Immutable booking fields copied at ledger create (audit).
class ChaletBookingSnapshot {
  const ChaletBookingSnapshot({
    this.startDate,
    this.endDate,
    this.pricePerNight,
    this.daysCount,
    this.propertyTitle,
  });

  final DateTime? startDate;
  final DateTime? endDate;
  final double? pricePerNight;
  final int? daysCount;
  final String? propertyTitle;

  static ChaletBookingSnapshot? tryParse(Map<String, dynamic>? m) {
    if (m == null || m.isEmpty) return null;
    return ChaletBookingSnapshot(
      startDate: _ts(m['startDate']),
      endDate: _ts(m['endDate']),
      pricePerNight: m.containsKey('pricePerNight') ? _num(m['pricePerNight']) : null,
      daysCount: _optionalInt(m['daysCount']),
      propertyTitle: m['propertyTitle']?.toString(),
    );
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  static int? _optionalInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static DateTime? _ts(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }
}

class ChaletBookingTransaction {
  const ChaletBookingTransaction({
    required this.id,
    required this.propertyId,
    required this.bookingId,
    required this.ownerId,
    this.ownerName = '',
    this.ownerPhone = '',
    this.ownerDisplayName = '',
    this.ownerSnapshot,
    required this.clientId,
    required this.amount,
    required this.commissionRate,
    required this.commissionAmount,
    required this.netAmount,
    required this.ownerPayoutAmount,
    required this.platformRevenue,
    required this.paymentVerified,
    required this.currency,
    required this.status,
    required this.payoutStatus,
    this.refundAmount = 0,
    this.refundStatus = 'none',
    this.refundReference,
    this.isFinalized = false,
    this.hasIssue = false,
    this.isDeleted = false,
    this.pricePerNight,
    this.daysCount,
    this.bookingSnapshot,
    this.createdBy,
    this.createdAt,
    this.updatedAt,
    this.confirmedAt,
    this.paidOutAt,
    this.payoutMethod,
    this.notes,
    this.bookingVersion,
    this.paymentReference,
    this.payoutReference,
  });

  final String id;
  final String propertyId;
  final String bookingId;
  final String ownerId;
  /// Snapshot from `users/{ownerId}` at ledger create; empty for legacy rows.
  final String ownerName;
  final String ownerPhone;
  /// Same as [ownerName] when set; optional explicit display field from backend.
  final String ownerDisplayName;
  /// Structured copy of owner identity at ledger create (optional on legacy rows).
  final ChaletOwnerSnapshot? ownerSnapshot;
  final String clientId;
  final double amount;
  final double commissionRate;
  final double commissionAmount;
  final double netAmount;
  /// Remaining net owed to owner after refunds (defaults to [netAmount] on legacy rows).
  final double ownerPayoutAmount;
  /// Same as commission at create; explicit platform revenue line for reporting.
  final double platformRevenue;
  /// Payment gateway readiness; true for current manual confirmation flow.
  final bool paymentVerified;
  final String currency;
  /// Ledger: pending | confirmed | cancelled | refunded
  final String status;
  final String payoutStatus;
  final double refundAmount;
  /// none | partial | full
  final String refundStatus;
  final String? refundReference;
  /// Terminal ledger row: no further automated mutations (paid out or refund fully closed payout).
  final bool isFinalized;
  /// Admin warning: anomaly flagged on server (invalid/mismatched state).
  final bool hasIssue;
  final bool isDeleted;
  final double? pricePerNight;
  final int? daysCount;
  final ChaletBookingSnapshot? bookingSnapshot;
  final String? createdBy;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? confirmedAt;
  final DateTime? paidOutAt;
  final String? payoutMethod;
  final String? notes;
  final int? bookingVersion;
  final String? paymentReference;
  final String? payoutReference;

  /// Human-friendly owner label; use [unknownOwner] from l10n when name is missing (avoid raw uid).
  String displayOwnerLabel(String unknownOwner) {
    final n = ownerName.trim();
    if (n.isNotEmpty) return n;
    return unknownOwner;
  }

  static String _strField(dynamic v) {
    if (v == null) return '';
    return v.toString().trim();
  }

  static double _num(dynamic v, [double fallback = 0]) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  static int? _optionalInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static DateTime? _ts(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }

  static ChaletBookingTransaction? tryParse(
    String id,
    Map<String, dynamic> d,
  ) {
    if ((d['type'] ?? '').toString() != 'booking') return null;
    if ((d['source'] ?? '').toString() != 'chalet_daily') return null;
    final statusStr = (d['status'] ?? 'confirmed').toString();
    final comm = _num(d['commissionAmount']);
    final net = _num(d['netAmount']);
    final ownerPayoutRaw = d['ownerPayoutAmount'];
    final ownerPayoutAmount =
        ownerPayoutRaw != null ? _num(ownerPayoutRaw) : net;
    final platformRevRaw = d['platformRevenue'];
    final platformRevenue = platformRevRaw != null ? _num(platformRevRaw) : comm;
    final paymentVerified = d['paymentVerified'] != false;
    final ownerSnap = ChaletOwnerSnapshot.tryParse(d['ownerSnapshot']);
    var ownName = _strField(d['ownerName']);
    var ownPhone = _strField(d['ownerPhone']);
    if (ownName.isEmpty && ownerSnap != null && ownerSnap.name.isNotEmpty) {
      ownName = ownerSnap.name;
    }
    if (ownPhone.isEmpty && ownerSnap != null && ownerSnap.phone.isNotEmpty) {
      ownPhone = ownerSnap.phone;
    }
    final ownDisplay = _strField(d['ownerDisplayName']);
    final snapRaw = d['bookingSnapshot'];
    Map<String, dynamic>? snapMap;
    if (snapRaw is Map<String, dynamic>) {
      snapMap = snapRaw;
    } else if (snapRaw is Map) {
      snapMap = Map<String, dynamic>.from(snapRaw);
    }

    return ChaletBookingTransaction(
      id: id,
      propertyId: d['propertyId']?.toString() ?? '',
      bookingId: d['bookingId']?.toString() ?? '',
      ownerId: d['ownerId']?.toString() ?? '',
      ownerName: ownName,
      ownerPhone: ownPhone,
      ownerDisplayName: ownDisplay.isNotEmpty ? ownDisplay : ownName,
      ownerSnapshot: ownerSnap,
      clientId: d['clientId']?.toString() ?? '',
      amount: _num(d['amount']),
      commissionRate: _num(d['commissionRate'], 0.1),
      commissionAmount: comm,
      netAmount: net,
      ownerPayoutAmount: ownerPayoutAmount,
      platformRevenue: platformRevenue,
      paymentVerified: paymentVerified,
      currency: (d['currency'] ?? 'KWD').toString(),
      status: statusStr.isEmpty ? 'confirmed' : statusStr,
      payoutStatus: (d['payoutStatus'] ?? '').toString(),
      refundAmount: _num(d['refundAmount']),
      refundStatus: (d['refundStatus'] ?? 'none').toString(),
      refundReference: d['refundReference']?.toString(),
      isFinalized: d['isFinalized'] == true,
      hasIssue: d['hasIssue'] == true,
      isDeleted: d['isDeleted'] == true,
      pricePerNight: d.containsKey('pricePerNight') ? _num(d['pricePerNight']) : null,
      daysCount: _optionalInt(d['daysCount']),
      bookingSnapshot: ChaletBookingSnapshot.tryParse(snapMap),
      createdBy: d['createdBy']?.toString(),
      createdAt: _ts(d['createdAt']),
      updatedAt: _ts(d['updatedAt']),
      confirmedAt: _ts(d['confirmedAt']),
      paidOutAt: _ts(d['paidOutAt']),
      payoutMethod: d['payoutMethod']?.toString(),
      notes: d['notes']?.toString(),
      bookingVersion: _optionalInt(d['bookingVersion']),
      paymentReference: d['paymentReference']?.toString(),
      payoutReference: d['payoutReference']?.toString(),
    );
  }
}
