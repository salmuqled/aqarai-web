// Read model for `transactions/{id}` booking-ledger rows (chalet, property sale/rent).

import 'package:cloud_firestore/cloud_firestore.dart';

/// Normalized `source` values the admin dashboard lists.
abstract final class LedgerTransactionSource {
  LedgerTransactionSource._();

  static const String chaletDaily = 'chalet_daily';
  static const String propertySale = 'property_sale';
  static const String propertyRent = 'property_rent';
  /// Fallback bucket for missing or unrecognized `source` values (display only).
  static const String other = 'other';
}

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
    try {
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
    } catch (_) {
      return null;
    }
  }

  static String _trim(dynamic v) {
    if (v == null) return '';
    return v.toString().trim();
  }
}

/// Immutable booking/deal audit snapshot at ledger create.
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
    try {
      if (m == null || m.isEmpty) return null;
      return ChaletBookingSnapshot(
        startDate: _ts(m['startDate']),
        endDate: _ts(m['endDate']),
        pricePerNight: m.containsKey('pricePerNight') ? _num(m['pricePerNight']) : null,
        daysCount: _optionalInt(m['daysCount']),
        propertyTitle: m['propertyTitle']?.toString(),
      );
    } catch (_) {
      return null;
    }
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

/// Unified read model for booking-shaped ledger documents in [transactions].
class TransactionModel {
  const TransactionModel({
    required this.id,
    required this.propertyId,
    required this.bookingId,
    this.dealId = '',
    this.source = LedgerTransactionSource.chaletDaily,
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
    this.integrityAmountMissingOrInvalid = false,
    this.integritySourceNonCanonical = false,
    this.integrityReferenceUsesDocIdOnly = false,
    this.integrityRecoveredFromParseException = false,
  });

  final String id;
  final String propertyId;
  final String bookingId;
  /// Deal / closure reference when present (property sale & rent ledgers).
  final String dealId;
  /// Normalized ledger source ([LedgerTransactionSource] values, including [LedgerTransactionSource.other]).
  final String source;
  final String ownerId;
  final String ownerName;
  final String ownerPhone;
  final String ownerDisplayName;
  final ChaletOwnerSnapshot? ownerSnapshot;
  final String clientId;
  final double amount;
  final double commissionRate;
  final double commissionAmount;
  final double netAmount;
  final double ownerPayoutAmount;
  final double platformRevenue;
  final bool paymentVerified;
  final String currency;
  final String status;
  final String payoutStatus;
  final double refundAmount;
  final String refundStatus;
  final String? refundReference;
  final bool isFinalized;
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

  /// UI-only flags for incomplete or abnormal Firestore payloads.
  final bool integrityAmountMissingOrInvalid;
  final bool integritySourceNonCanonical;
  final bool integrityReferenceUsesDocIdOnly;
  final bool integrityRecoveredFromParseException;

  bool get isChaletDailyLedger => source == LedgerTransactionSource.chaletDaily;

  bool get hasAdminIntegrityWarnings =>
      integrityAmountMissingOrInvalid ||
      integritySourceNonCanonical ||
      integrityReferenceUsesDocIdOnly ||
      integrityRecoveredFromParseException;

  String displayOwnerLabel(String unknownOwner) {
    final n = ownerName.trim();
    if (n.isNotEmpty) return n;
    return unknownOwner;
  }

  /// Resolved listing headline: snapshot title, else [propertyId], else [unknownPropertyLabel].
  String displayPropertyHeadline(String unknownPropertyLabel) {
    final t = bookingSnapshot?.propertyTitle?.trim();
    if (t != null && t.isNotEmpty) return t;
    if (propertyId.isNotEmpty) return propertyId;
    return unknownPropertyLabel;
  }

  /// `bookingId`, else `dealId`, else Firestore document id (always non-empty when [id] is non-empty).
  String get referenceId {
    if (bookingId.isNotEmpty) return bookingId;
    if (dealId.isNotEmpty) return dealId;
    return id;
  }

  static Map<String, dynamic> _safeDataMap(Map<String, dynamic> d) {
    try {
      return Map<String, dynamic>.from(d);
    } catch (_) {
      return {};
    }
  }

  static (String canonical, bool integritySource) _resolveSource(String rawLower) {
    if (rawLower.isEmpty) {
      return (LedgerTransactionSource.other, true);
    }
    switch (rawLower) {
      case LedgerTransactionSource.chaletDaily:
        return (LedgerTransactionSource.chaletDaily, false);
      case LedgerTransactionSource.propertySale:
      case 'deal_sale':
      case 'sale':
        return (LedgerTransactionSource.propertySale, false);
      case LedgerTransactionSource.propertyRent:
      case 'deal_rent':
      case 'rent':
        return (LedgerTransactionSource.propertyRent, false);
      case LedgerTransactionSource.other:
        return (LedgerTransactionSource.other, false);
      default:
        return (LedgerTransactionSource.other, true);
    }
  }

  static String _strField(dynamic v) {
    if (v == null) return '';
    return v.toString().trim();
  }

  static double _num(dynamic v, [double fallback = 0]) {
    if (v is num) {
      final x = v.toDouble();
      return x.isFinite ? x : fallback;
    }
    if (v is String) {
      final x = double.tryParse(v) ?? fallback;
      return x.isFinite ? x : fallback;
    }
    return fallback;
  }

  static bool _amountMissingOrInvalid(Map<String, dynamic> d) {
    try {
      if (!d.containsKey('amount')) return true;
      final v = d['amount'];
      if (v == null) return true;
      if (v is bool) return true;
      if (v is! num && v is! String) return true;
      final n = _num(v, double.nan);
      return !n.isFinite;
    } catch (_) {
      return true;
    }
  }

  static int? _optionalInt(dynamic v) {
    try {
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) return int.tryParse(v);
      return null;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _ts(dynamic v) {
    try {
      if (v is Timestamp) return v.toDate();
      return null;
    } catch (_) {
      return null;
    }
  }

  static TransactionModel _recoveryModel(String id, Map<String, dynamic> d) {
    final data = _safeDataMap(d);
    return TransactionModel(
      id: id,
      propertyId: _strField(data['propertyId']),
      bookingId: _strField(data['bookingId']),
      dealId: _strField(data['dealId']),
      source: LedgerTransactionSource.other,
      ownerId: _strField(data['ownerId']),
      clientId: _strField(data['clientId']),
      amount: 0,
      commissionRate: 0.1,
      commissionAmount: 0,
      netAmount: 0,
      ownerPayoutAmount: 0,
      platformRevenue: 0,
      paymentVerified: false,
      currency: _strField(data['currency']).isEmpty ? 'KWD' : _strField(data['currency']),
      status: 'confirmed',
      payoutStatus: _strField(data['payoutStatus']),
      integrityAmountMissingOrInvalid: true,
      integritySourceNonCanonical: true,
      integrityReferenceUsesDocIdOnly: true,
      integrityRecoveredFromParseException: true,
    );
  }

  /// Parses a `transactions/{id}` booking ledger row. Never throws; returns `null` only for non-booking types or empty [id].
  static TransactionModel? parse(String id, Map<String, dynamic> d) {
    if (id.isEmpty) return null;
    try {
      if (_strField(d['type']) != 'booking') return null;
      return _parseBookingLedger(id, _safeDataMap(d));
    } catch (_) {
      try {
        if (_strField(d['type']) != 'booking') return null;
        return _recoveryModel(id, d);
      } catch (_) {
        return null;
      }
    }
  }

  static TransactionModel _parseBookingLedger(String id, Map<String, dynamic> d) {
    final rawSrc = _strField(d['source']).toLowerCase();
    final (canonicalSource, sourceIntegrity) = _resolveSource(rawSrc);

    final bookingId = _strField(d['bookingId']);
    final dealId = _strField(d['dealId']);
    final referenceThin = bookingId.isEmpty && dealId.isEmpty;

    final statusStr = (d['status'] ?? 'confirmed').toString();
    final amountBad = _amountMissingOrInvalid(d);
    final gross = amountBad ? 0.0 : _num(d['amount'], 0);

    final comm = _num(d['commissionAmount'], 0);
    final net = _num(d['netAmount'], 0);
    final ownerPayoutRaw = d['ownerPayoutAmount'];
    final ownerPayoutAmount =
        ownerPayoutRaw != null ? _num(ownerPayoutRaw, net) : net;
    final platformRevRaw = d['platformRevenue'];
    final platformRevenue = platformRevRaw != null ? _num(platformRevRaw, comm) : comm;
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

    Map<String, dynamic>? snapMap;
    try {
      final snapRaw = d['bookingSnapshot'];
      if (snapRaw is Map<String, dynamic>) {
        snapMap = snapRaw;
      } else if (snapRaw is Map) {
        snapMap = Map<String, dynamic>.from(snapRaw);
      }
    } catch (_) {
      snapMap = null;
    }

    return TransactionModel(
      id: id,
      propertyId: _strField(d['propertyId']),
      bookingId: bookingId,
      dealId: dealId,
      source: canonicalSource,
      ownerId: _strField(d['ownerId']),
      ownerName: ownName,
      ownerPhone: ownPhone,
      ownerDisplayName: ownDisplay.isNotEmpty ? ownDisplay : ownName,
      ownerSnapshot: ownerSnap,
      clientId: _strField(d['clientId']),
      amount: gross,
      commissionRate: _num(d['commissionRate'], 0.1),
      commissionAmount: comm,
      netAmount: net,
      ownerPayoutAmount: ownerPayoutAmount.isFinite ? ownerPayoutAmount : 0,
      platformRevenue: platformRevenue.isFinite ? platformRevenue : 0,
      paymentVerified: paymentVerified,
      currency: _strField(d['currency']).isEmpty ? 'KWD' : _strField(d['currency']),
      status: statusStr.isEmpty ? 'confirmed' : statusStr,
      payoutStatus: (d['payoutStatus'] ?? '').toString(),
      refundAmount: _num(d['refundAmount'], 0),
      refundStatus: (d['refundStatus'] ?? 'none').toString(),
      refundReference: d['refundReference']?.toString(),
      isFinalized: d['isFinalized'] == true,
      hasIssue: d['hasIssue'] == true,
      isDeleted: d['isDeleted'] == true,
      pricePerNight: d.containsKey('pricePerNight') ? _num(d['pricePerNight'], 0) : null,
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
      integrityAmountMissingOrInvalid: amountBad,
      integritySourceNonCanonical: sourceIntegrity,
      integrityReferenceUsesDocIdOnly: referenceThin,
      integrityRecoveredFromParseException: false,
    );
  }
}
