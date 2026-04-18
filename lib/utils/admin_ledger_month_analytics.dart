// Client-side aggregates for admin ledger (current calendar month, local time).

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/transaction_model.dart';

/// Revenue and counts for the **current calendar month** from a loaded doc batch.
///
/// Uses:
/// - Platform revenue: [TransactionModel.platformRevenue]
/// - Total volume (GMV): [TransactionModel.amount]
///
/// Monthly bucket uses: `createdAt ?? confirmedAt ?? updatedAt` only.
/// Rows with **no** valid timestamp are counted in [undatedRowsCount] and are
/// **excluded** from all monthly totals (revenue, volume, breakdown, top property).
class AdminLedgerMonthAnalytics {
  const AdminLedgerMonthAnalytics({
    required this.totalPlatformRevenue,
    required this.totalVolume,
    required this.transactionCount,
    required this.chaletRevenue,
    required this.saleRevenue,
    required this.rentRevenue,
    required this.otherRevenue,
    required this.chaletVolume,
    required this.saleVolume,
    required this.rentVolume,
    required this.otherVolume,
    required this.topPropertyId,
    required this.topPropertyDisplayLabel,
    required this.topPropertyRevenue,
    required this.undatedRowsCount,
    required this.hitsClientLimit,
    required this.limit,
  });

  final double totalPlatformRevenue;
  final double totalVolume;
  final int transactionCount;
  final double chaletRevenue;
  final double saleRevenue;
  final double rentRevenue;
  final double otherRevenue;
  final double chaletVolume;
  final double saleVolume;
  final double rentVolume;
  final double otherVolume;
  final String? topPropertyId;
  final String topPropertyDisplayLabel;
  final double topPropertyRevenue;
  /// Parsed ledger rows with no `createdAt`, `confirmedAt`, or `updatedAt` (excluded from month stats).
  final int undatedRowsCount;
  /// True when analytics are computed from a capped client query that likely truncated history.
  final bool hitsClientLimit;
  final int limit;

  bool get hasTopProperty =>
      topPropertyId != null &&
      topPropertyId!.isNotEmpty &&
      topPropertyRevenue > 0;

  static double _safeRev(TransactionModel row) {
    final v = row.platformRevenue;
    if (!v.isFinite || v < 0) return 0;
    return v;
  }

  static double _safeAmount(TransactionModel row) {
    final v = row.amount;
    if (!v.isFinite || v < 0) return 0;
    return v;
  }

  static DateTime _monthStart(DateTime now) => DateTime(now.year, now.month, 1);

  static DateTime _monthEndExclusive(DateTime now) =>
      DateTime(now.year, now.month + 1, 1);

  static DateTime? _referenceDay(TransactionModel row) =>
      row.createdAt ?? row.confirmedAt ?? row.updatedAt;

  /// Aggregates [docs] for the month containing [asOf] (default: `DateTime.now()`).
  static AdminLedgerMonthAnalytics fromDocuments(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
    required String unknownPropertyLabel,
    required int limit,
    DateTime? asOf,
  }) {
    final now = asOf ?? DateTime.now();
    final start = _monthStart(now);
    final end = _monthEndExclusive(now);

    var total = 0.0;
    var totalVolume = 0.0;
    var count = 0;
    var chalet = 0.0;
    var sale = 0.0;
    var rent = 0.0;
    var other = 0.0;
    var chaletVol = 0.0;
    var saleVol = 0.0;
    var rentVol = 0.0;
    var otherVol = 0.0;
    var undated = 0;

    final byProperty = <String, double>{};
    final sampleByProperty = <String, TransactionModel>{};

    var docsLen = 0;
    for (final d in docs) {
      docsLen++;
      TransactionModel? row;
      try {
        row = TransactionModel.parse(d.id, d.data());
      } catch (_) {
        continue;
      }
      if (row == null || row.isDeleted) continue;

      final ref = _referenceDay(row);
      if (ref == null) {
        undated++;
        continue;
      }
      if (ref.isBefore(start) || !ref.isBefore(end)) continue;

      final rev = _safeRev(row);
      final gmv = _safeAmount(row);
      total += rev;
      totalVolume += gmv;
      count++;

      switch (row.source) {
        case LedgerTransactionSource.chaletDaily:
          chalet += rev;
          chaletVol += gmv;
          break;
        case LedgerTransactionSource.propertySale:
          sale += rev;
          saleVol += gmv;
          break;
        case LedgerTransactionSource.propertyRent:
          rent += rev;
          rentVol += gmv;
          break;
        default:
          other += rev;
          otherVol += gmv;
          break;
      }

      final pid = row.propertyId.trim();
      if (pid.isEmpty) continue;
      byProperty[pid] = (byProperty[pid] ?? 0) + rev;
      sampleByProperty.putIfAbsent(pid, () => row!);
    }

    String? topId;
    var topRev = 0.0;
    for (final e in byProperty.entries) {
      if (e.value > topRev) {
        topRev = e.value;
        topId = e.key;
      }
    }

    final topLabel = topId != null
        ? sampleByProperty[topId]!.displayPropertyHeadline(unknownPropertyLabel)
        : '';

    return AdminLedgerMonthAnalytics(
      totalPlatformRevenue: total,
      totalVolume: totalVolume,
      transactionCount: count,
      chaletRevenue: chalet,
      saleRevenue: sale,
      rentRevenue: rent,
      otherRevenue: other,
      chaletVolume: chaletVol,
      saleVolume: saleVol,
      rentVolume: rentVol,
      otherVolume: otherVol,
      topPropertyId: topId,
      topPropertyDisplayLabel: topLabel,
      topPropertyRevenue: topRev,
      undatedRowsCount: undated,
      hitsClientLimit: docsLen >= limit,
      limit: limit,
    );
  }
}
