import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';
import 'package:aqarai_app/utils/kuwait_calendar.dart';

/// Earnings time window (drives Firestore queries).
enum EarningsDateRangePreset {
  /// No date predicates; all paid requests / sold deals.
  allTime,

  /// Start of today → end of today (Kuwait calendar, UTC+3).
  today,

  /// Last 7 Kuwait calendar days including Kuwait today (today − 6 … today).
  last7Days,

  /// Last 30 Kuwait calendar days including Kuwait today (today − 29 … today).
  last30Days,
}

/// Resolved window for aggregation UI (chart gap-fill only when [isWindowed]).
class EarningsDateRange {
  const EarningsDateRange._({
    required this.isWindowed,
    this.startInclusive,
    this.endExclusive,
    this.startDateKuwait,
    this.endDateKuwaitInclusive,
  });

  /// `false` for [EarningsDateRangePreset.allTime].
  final bool isWindowed;

  /// Firestore `>=` on `auctionFeePaidAt` / `createdAt` (only if [isWindowed]).
  final Timestamp? startInclusive;

  /// Firestore `<` upper bound (start of day after last included day).
  final Timestamp? endExclusive;

  /// Chart: first day in window (Kuwait `yyyy-MM-dd`, stored as `DateTime.utc(y,m,d)`).
  final DateTime? startDateKuwait;

  /// Chart: last day in window (inclusive), same encoding as [startDateKuwait].
  final DateTime? endDateKuwaitInclusive;

  static const EarningsDateRange allTime = EarningsDateRange._(isWindowed: false);

  /// Kuwait calendar window ending on Kuwait “today” (for today / 7d / 30d presets).
  ///
  /// Query bounds are **UTC instants** ([KuwaitCalendar.timestampFromUtcInstant]);
  /// Kuwait “today” uses [KuwaitCalendar.kuwaitTodayDateOnly] (not device local).
  static EarningsDateRange windowed(EarningsDateRangePreset preset) {
    assert(preset != EarningsDateRangePreset.allTime);
    final todayKuwait = KuwaitCalendar.kuwaitTodayDateOnly();
    final tomorrowKuwait = todayKuwait.add(const Duration(days: 1));

    late final DateTime rangeStartKuwait;
    switch (preset) {
      case EarningsDateRangePreset.allTime:
        throw StateError('Use EarningsDateRange.allTime');
      case EarningsDateRangePreset.today:
        rangeStartKuwait = todayKuwait;
      case EarningsDateRangePreset.last7Days:
        rangeStartKuwait = todayKuwait.subtract(const Duration(days: 6));
      case EarningsDateRangePreset.last30Days:
        rangeStartKuwait = todayKuwait.subtract(const Duration(days: 29));
    }

    final startUtc = KuwaitCalendar.utcInstantStartOfKuwaitDay(rangeStartKuwait);
    final endUtc = KuwaitCalendar.utcInstantStartOfKuwaitDay(tomorrowKuwait);

    return EarningsDateRange._(
      isWindowed: true,
      startInclusive: KuwaitCalendar.timestampFromUtcInstant(startUtc),
      endExclusive: KuwaitCalendar.timestampFromUtcInstant(endUtc),
      startDateKuwait: rangeStartKuwait,
      endDateKuwaitInclusive: todayKuwait,
    );
  }

  static EarningsDateRange fromPreset(EarningsDateRangePreset preset) {
    if (preset == EarningsDateRangePreset.allTime) return allTime;
    return windowed(preset);
  }
}

/// Real-time admin earnings from Firestore only (no `analytics/global`).
///
/// All filtering is in Firestore:
/// - Paid requests: `auctionFeeStatus == paid`, and when windowed,
///   `auctionFeePaidAt` in `[start, end)`.
/// - Sold deals: `status == sold`, and when windowed, `createdAt` in `[start, end)`.
///
/// Window bounds are **UTC**; grouping uses **Kuwait civil calendar** via
/// [KuwaitCalendar] (UTC+3). See `lib/utils/kuwait_calendar.dart`.
///
/// Windowed queries need composite indexes (see `firestore.indexes.json`).
abstract final class AdminRealEarningsService {
  AdminRealEarningsService._();

  static Query<Map<String, dynamic>> paidAuctionRequestsQuery(
    FirebaseFirestore db, {
    required EarningsDateRangePreset preset,
  }) {
    final col = db.collection(AuctionFirestorePaths.auctionRequests);
    if (preset == EarningsDateRangePreset.allTime) {
      return col.where('auctionFeeStatus', isEqualTo: 'paid');
    }
    final w = EarningsDateRange.windowed(preset);
    return col
        .where('auctionFeeStatus', isEqualTo: 'paid')
        .where('auctionFeePaidAt', isGreaterThanOrEqualTo: w.startInclusive!)
        .where('auctionFeePaidAt', isLessThan: w.endExclusive!)
        .orderBy('auctionFeePaidAt');
  }

  static Query<Map<String, dynamic>> soldDealsQuery(
    FirebaseFirestore db, {
    required EarningsDateRangePreset preset,
  }) {
    final col = db.collection('deals');
    if (preset == EarningsDateRangePreset.allTime) {
      return col.where('status', isEqualTo: 'sold');
    }
    final w = EarningsDateRange.windowed(preset);
    return col
        .where('status', isEqualTo: 'sold')
        .where('createdAt', isGreaterThanOrEqualTo: w.startInclusive!)
        .where('createdAt', isLessThan: w.endExclusive!)
        .orderBy('createdAt');
  }

  static double _money(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim()) ?? 0;
  }

  static DateTime? _dayFromPaidRequest(Map<String, dynamic> m) {
    for (final key in ['auctionFeePaidAt', 'createdAt']) {
      final v = m[key];
      if (v is Timestamp) return KuwaitCalendar.kuwaitDateOnlyFromTimestamp(v);
    }
    return null;
  }

  static DateTime? _dayFromSoldDeal(Map<String, dynamic> m) {
    for (final key in ['createdAt', 'closedAt']) {
      final v = m[key];
      if (v is Timestamp) return KuwaitCalendar.kuwaitDateOnlyFromTimestamp(v);
    }
    return null;
  }

  static String _dayKeyKuwait(DateTime kuwaitYmd) =>
      '${kuwaitYmd.year}-${kuwaitYmd.month.toString().padLeft(2, '0')}-${kuwaitYmd.day.toString().padLeft(2, '0')}';

  /// One row per calendar day in the window (zeros where no revenue).
  static List<DailyRevenuePoint> _seriesWithGaps(
    Map<String, double> daily,
    EarningsDateRange filterRange,
  ) {
    final out = <DailyRevenuePoint>[];
    var d = filterRange.startDateKuwait!;
    final end = filterRange.endDateKuwaitInclusive!;
    while (!d.isAfter(end)) {
      final k = _dayKeyKuwait(d);
      out.add(DailyRevenuePoint(dayKey: k, revenueKwd: daily[k] ?? 0));
      d = d.add(const Duration(days: 1));
    }
    return out;
  }

  /// All-time: only days with revenue, sorted (avoids huge zero-filled series).
  static List<DailyRevenuePoint> _seriesSparseSorted(Map<String, double> daily) {
    final keys = daily.keys.toList()..sort();
    return [
      for (final k in keys)
        DailyRevenuePoint(dayKey: k, revenueKwd: daily[k] ?? 0),
    ];
  }

  /// Top-card metrics + chart from query snapshots (already Firestore-filtered).
  static RealEarningsSnapshot aggregate(
    QuerySnapshot<Map<String, dynamic>> paidRequestsSnap,
    QuerySnapshot<Map<String, dynamic>> soldDealsSnap, {
    required EarningsDateRange filterRange,
  }) {
    final paidDocs = paidRequestsSnap.docs;
    final soldDocs = soldDealsSnap.docs;

    var feesSum = 0.0;
    for (final d in paidDocs) {
      feesSum += _money(d.data()['auctionFee']);
    }

    var commissionSum = 0.0;
    for (final d in soldDocs) {
      commissionSum += _money(d.data()['commissionAmount']);
    }

    final daily = <String, double>{};

    for (final d in paidDocs) {
      final m = d.data();
      final day = _dayFromPaidRequest(m);
      if (day == null) continue;
      final k = _dayKeyKuwait(day);
      daily[k] = (daily[k] ?? 0) + _money(m['auctionFee']);
    }

    for (final d in soldDocs) {
      final m = d.data();
      final day = _dayFromSoldDeal(m);
      if (day == null) continue;
      final k = _dayKeyKuwait(day);
      daily[k] = (daily[k] ?? 0) + _money(m['commissionAmount']);
    }

    final List<DailyRevenuePoint> series = filterRange.isWindowed
        ? _seriesWithGaps(daily, filterRange)
        : _seriesSparseSorted(daily);

    return RealEarningsSnapshot(
      paidAuctionCount: paidDocs.length,
      soldDealCount: soldDocs.length,
      totalAuctionFeesKwd: feesSum,
      totalCommissionKwd: commissionSum,
      totalRevenueKwd: feesSum + commissionSum,
      dailyRevenue: series,
    );
  }
}

/// Aggregated view for the real earnings dashboard.
class RealEarningsSnapshot {
  const RealEarningsSnapshot({
    required this.paidAuctionCount,
    required this.soldDealCount,
    required this.totalAuctionFeesKwd,
    required this.totalCommissionKwd,
    required this.totalRevenueKwd,
    required this.dailyRevenue,
  });

  final int paidAuctionCount;
  final int soldDealCount;
  final double totalAuctionFeesKwd;
  final double totalCommissionKwd;

  /// Sum(auction fees on paid requests) + sum(commission on sold deals).
  final double totalRevenueKwd;

  /// Chronological days in the selected filter (including zeros).
  final List<DailyRevenuePoint> dailyRevenue;
}

class DailyRevenuePoint {
  const DailyRevenuePoint({
    required this.dayKey,
    required this.revenueKwd,
  });

  /// `yyyy-MM-dd` (Kuwait calendar date, UTC+3).
  final String dayKey;
  final double revenueKwd;
}
