import 'package:aqarai_app/models/financial_ledger.dart';
import 'package:aqarai_app/models/invoice.dart';
import 'package:aqarai_app/utils/kuwait_calendar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Admin read-only: `invoices` list + `financial_ledger` revenue summary.
abstract final class AdminInvoicesService {
  AdminInvoicesService._();

  static const int pageFetchBatch = 50;
  static const int targetRowsPerLoad = 20;
  static const int ledgerSummaryBatch = 400;
  static const int ledgerSummaryMaxBatches = 80;

  /// Firestore: [serviceType] + [createdAt] range + order by [createdAt] desc.
  /// Substring search is applied client-side only.
  static Query<Map<String, dynamic>> baseQuery(
    FirebaseFirestore db, {
    String? serviceType,
    DateTime? createdFromKuwaitDayUtc,
    DateTime? createdToKuwaitDayInclusiveUtc,
  }) {
    Query<Map<String, dynamic>> q = db.collection(InvoiceFields.collection);

    if (serviceType != null && serviceType.isNotEmpty) {
      q = q.where(InvoiceFields.serviceType, isEqualTo: serviceType);
    }

    if (createdFromKuwaitDayUtc != null) {
      final start = KuwaitCalendar.utcInstantStartOfKuwaitDay(
        createdFromKuwaitDayUtc,
      );
      q = q.where(
        InvoiceFields.createdAt,
        isGreaterThanOrEqualTo: Timestamp.fromDate(start),
      );
    }

    if (createdToKuwaitDayInclusiveUtc != null) {
      final nextDay = createdToKuwaitDayInclusiveUtc.add(
        const Duration(days: 1),
      );
      final endExclusive = KuwaitCalendar.utcInstantStartOfKuwaitDay(nextDay);
      q = q.where(
        InvoiceFields.createdAt,
        isLessThan: Timestamp.fromDate(endExclusive),
      );
    }

    q = q.orderBy(InvoiceFields.createdAt, descending: true);
    return q;
  }

  /// Aggregates `financial_ledger` rows: type=income, source=invoice.
  static Future<InvoiceGlobalSummary> loadGlobalSummary(
    FirebaseFirestore db,
  ) async {
    final todayKuwait = KuwaitCalendar.kuwaitTodayDateOnly();

    QueryDocumentSnapshot<Map<String, dynamic>>? cursor;
    var totalRev = 0.0;
    var count = 0;
    var monthRev = 0.0;

    for (var b = 0; b < ledgerSummaryMaxBatches; b++) {
      Query<Map<String, dynamic>> q = db
          .collection(FinancialLedgerFields.collection)
          .where(FinancialLedgerFields.type, isEqualTo: FinancialLedgerType.income)
          .where(FinancialLedgerFields.source, isEqualTo: FinancialLedgerSource.invoice)
          .orderBy(FinancialLedgerFields.createdAt, descending: true)
          .limit(ledgerSummaryBatch);
      if (cursor != null) {
        q = q.startAfterDocument(cursor);
      }
      final snap = await q.get();
      if (snap.docs.isEmpty) break;

      for (final d in snap.docs) {
        count++;
        final m = d.data();
        final raw = m[FinancialLedgerFields.amount];
        double amt = 0;
        if (raw is num) {
          amt = raw.toDouble();
        } else if (raw != null) {
          amt = double.tryParse(raw.toString()) ?? 0;
        }
        totalRev += amt;
        final ts = m[FinancialLedgerFields.createdAt] as Timestamp?;
        if (ts != null) {
          final kuwaitDay = KuwaitCalendar.kuwaitDateOnlyFromTimestamp(ts);
          if (kuwaitDay.year == todayKuwait.year &&
              kuwaitDay.month == todayKuwait.month) {
            monthRev += amt;
          }
        }
      }

      cursor = snap.docs.last;
      if (snap.docs.length < ledgerSummaryBatch) break;
    }

    return InvoiceGlobalSummary(
      totalRevenueKwd: totalRev,
      ledgerEntryCount: count,
      thisMonthRevenueKwd: monthRev,
    );
  }
}
