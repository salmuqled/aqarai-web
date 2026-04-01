import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/services/admin_real_earnings_service.dart';
import 'package:aqarai_app/services/company_payments_service.dart';

/// Combines real earnings (fees + commission) with `company_payments` cash ledger.
class AdminCashflowLedgerSection extends StatefulWidget {
  const AdminCashflowLedgerSection({
    super.key,
    required this.fmtKwd,
    required this.isAr,
  });

  final String Function(num n) fmtKwd;
  final bool isAr;

  @override
  State<AdminCashflowLedgerSection> createState() =>
      _AdminCashflowLedgerSectionState();
}

class _AdminCashflowLedgerSectionState extends State<AdminCashflowLedgerSection> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subPaid;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subSold;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subLedger;

  QuerySnapshot<Map<String, dynamic>>? _paidSnap;
  QuerySnapshot<Map<String, dynamic>>? _soldSnap;
  QuerySnapshot<Map<String, dynamic>>? _ledgerSnap;

  @override
  void initState() {
    super.initState();
    _subPaid = AdminRealEarningsService.paidAuctionRequestsQuery(
      _db,
      preset: EarningsDateRangePreset.allTime,
    ).snapshots().listen((s) => setState(() => _paidSnap = s));
    _subSold = AdminRealEarningsService.soldDealsQuery(
      _db,
      preset: EarningsDateRangePreset.allTime,
    ).snapshots().listen((s) => setState(() => _soldSnap = s));
    _subLedger = CompanyPaymentsService.paymentsQuery(_db).snapshots().listen(
      (s) => setState(() => _ledgerSnap = s),
    );
  }

  @override
  void dispose() {
    unawaited(_subPaid?.cancel());
    unawaited(_subSold?.cancel());
    unawaited(_subLedger?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = widget.isAr;
    final paid = _paidSnap;
    final sold = _soldSnap;
    final ledger = _ledgerSnap;

    if (paid == null || sold == null || ledger == null) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  isAr ? 'جاري تحميل الصندوق والإيراد…' : 'Loading cash ledger & revenue…',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final range = EarningsDateRange.fromPreset(EarningsDateRangePreset.allTime);
    final agg = AdminRealEarningsService.aggregate(
      paid,
      sold,
      filterRange: range,
    );
    final cashTotals = CompanyPaymentsService.totalsFromPaymentDocs(ledger.docs);
    final recognized = agg.totalRevenueKwd;
    final pending = recognized - cashTotals.totalCashIn;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          isAr ? 'الصندوق والتحصيل' : 'Cash & collections',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          loc.companyCashflowSubtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 4),
        Text(
          loc.companyCashflowConfirmedOnlyHint,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 560;
            final cardRecognized = _CashMetricCard(
              label: isAr ? 'إيراد مُعرَّف' : 'Recognized revenue',
              value: widget.fmtKwd(recognized),
              icon: Icons.receipt_long_outlined,
              foot: isAr ? 'رسوم + عمولة (Firestore)' : 'Fees + commission (Firestore)',
            );
            final cardCash = _CashMetricCard(
              label: isAr ? 'إجمالي التحصيل' : 'Total cash in',
              value: widget.fmtKwd(cashTotals.totalCashIn),
              icon: Icons.payments_outlined,
              foot: loc.companyPaymentTotalCashFoot,
            );
            final cardPending = _CashMetricCard(
              label: isAr ? 'المتبقي' : 'Pending',
              value: widget.fmtKwd(pending),
              icon: Icons.hourglass_bottom_outlined,
              foot: pending >= 0
                  ? (isAr ? 'إيراد − تحصيل' : 'Revenue − cash')
                  : (isAr ? 'تحصيل أعلى من الإيراد المعروض' : 'Cash ahead of recognized revenue'),
            );
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cardRecognized),
                  const SizedBox(width: 10),
                  Expanded(child: cardCash),
                  const SizedBox(width: 10),
                  Expanded(child: cardPending),
                ],
              );
            }
            return Column(
              children: [
                cardRecognized,
                const SizedBox(height: 10),
                cardCash,
                const SizedBox(height: 10),
                cardPending,
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Text(
          isAr ? 'التحصيل حسب السبب' : 'Cash in by reason',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Colors.grey.shade800,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: Column(
              children: [
                _ReasonRow(
                  label: isAr ? 'مبيعات' : 'Sales',
                  amount: widget.fmtKwd(cashTotals.bySale),
                ),
                const Divider(height: 16),
                _ReasonRow(
                  label: isAr ? 'إيجار' : 'Rent',
                  amount: widget.fmtKwd(cashTotals.byRent),
                ),
                const Divider(height: 16),
                _ReasonRow(
                  label: isAr ? 'مزادات' : 'Auctions',
                  amount: widget.fmtKwd(cashTotals.byAuction),
                ),
                if (cashTotals.byOtherReason > 0) ...[
                  const Divider(height: 16),
                  _ReasonRow(
                    label: isAr ? 'أخرى / إدارة' : 'Other / management',
                    amount: widget.fmtKwd(cashTotals.byOtherReason),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CashMetricCard extends StatelessWidget {
  const _CashMetricCard({
    required this.label,
    required this.value,
    required this.icon,
    this.foot,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? foot;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.navy, size: 22),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (foot != null) ...[
              const SizedBox(height: 4),
              Text(
                foot!,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReasonRow extends StatelessWidget {
  const _ReasonRow({required this.label, required this.amount});

  final String label;
  final String amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          Text(
            amount,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
