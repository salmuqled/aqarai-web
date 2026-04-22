import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/transaction_model.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/chalet_booking_transaction_service.dart';
import 'package:aqarai_app/utils/admin_ledger_month_analytics.dart';

enum _LedgerGroupBy {
  none,
  source,
  property,
}

enum _SourceFilter {
  all,
  chaletDaily,
  propertySale,
  propertyRent,
  other,
}

extension on _SourceFilter {
  bool matches(TransactionModel row) {
    switch (this) {
      case _SourceFilter.all:
        return true;
      case _SourceFilter.chaletDaily:
        return row.source == LedgerTransactionSource.chaletDaily;
      case _SourceFilter.propertySale:
        return row.source == LedgerTransactionSource.propertySale;
      case _SourceFilter.propertyRent:
        return row.source == LedgerTransactionSource.propertyRent;
      case _SourceFilter.other:
        return row.source == LedgerTransactionSource.other;
    }
  }

  String title(AppLocalizations loc) {
    switch (this) {
      case _SourceFilter.all:
        return loc.adminLedgerFilterSourceAll;
      case _SourceFilter.chaletDaily:
        return loc.adminLedgerSourceChalet;
      case _SourceFilter.propertySale:
        return loc.adminLedgerSourceSale;
      case _SourceFilter.propertyRent:
        return loc.adminLedgerSourceRent;
      case _SourceFilter.other:
        return loc.adminLedgerSourceOther;
    }
  }
}

extension on _LedgerGroupBy {
  String title(AppLocalizations loc) {
    switch (this) {
      case _LedgerGroupBy.none:
        return loc.adminLedgerGroupNone;
      case _LedgerGroupBy.source:
        return loc.adminLedgerGroupSource;
      case _LedgerGroupBy.property:
        return loc.adminLedgerGroupProperty;
    }
  }
}

/// Admin: chalet booking ledger + manual payout after bank transfer.
class AdminChaletPayoutsPage extends StatefulWidget {
  const AdminChaletPayoutsPage({super.key});

  @override
  State<AdminChaletPayoutsPage> createState() => _AdminChaletPayoutsPageState();
}

class _AdminChaletPayoutsPageState extends State<AdminChaletPayoutsPage> {
  /// Default: payout queue only (`payoutStatus == pending`).
  bool _pendingPayoutsOnly = true;

  _LedgerGroupBy _groupBy = _LedgerGroupBy.none;
  _SourceFilter _sourceFilter = _SourceFilter.all;

  int _compareCreatedDesc(TransactionModel a, TransactionModel b) {
    final da = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final db = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return db.compareTo(da);
  }

  String _sourceLabel(TransactionModel row, AppLocalizations loc) {
    switch (row.source) {
      case LedgerTransactionSource.chaletDaily:
        return loc.adminLedgerSourceChalet;
      case LedgerTransactionSource.propertySale:
        return loc.adminLedgerSourceSale;
      case LedgerTransactionSource.propertyRent:
        return loc.adminLedgerSourceRent;
      case LedgerTransactionSource.other:
        return loc.adminLedgerSourceOther;
      default:
        return loc.adminLedgerUnknown;
    }
  }

  int _sourceGroupRank(String s) {
    if (s == LedgerTransactionSource.chaletDaily) return 0;
    if (s == LedgerTransactionSource.propertySale) return 1;
    if (s == LedgerTransactionSource.propertyRent) return 2;
    if (s == LedgerTransactionSource.other) return 3;
    return 99;
  }

  String _propertyHeadline(TransactionModel row, AppLocalizations loc) {
    return row.displayPropertyHeadline(loc.adminLedgerUnknownProperty);
  }

  String _referenceLabel(TransactionModel row, AppLocalizations loc) {
    if (row.bookingId.isNotEmpty) return loc.adminLedgerBookingRefLabel;
    if (row.dealId.isNotEmpty) return loc.adminLedgerDealRefLabel;
    return loc.adminLedgerRecordIdLabel;
  }

  Widget _moneyRow(
    String label,
    double value,
    NumberFormat fmt,
    String currency,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade800,
                height: 1.25,
              ),
            ),
          ),
          Text(
            '${fmt.format(value)} $currency',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _moneyRowTextValue(String label, String valueText, String currency) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade800,
                height: 1.25,
              ),
            ),
          ),
          Text(
            valueText == '—' ? '—' : '$valueText $currency',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: AppColors.navy,
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  List<Widget> _buildGroupedList(
    BuildContext context,
    List<TransactionModel> rows,
    AppLocalizations loc,
  ) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');

    switch (_groupBy) {
      case _LedgerGroupBy.none:
        rows.sort(_compareCreatedDesc);
        return [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _transactionCard(context, rows[i], loc, fmt),
          ],
        ];
      case _LedgerGroupBy.source:
        final map = <String, List<TransactionModel>>{};
        for (final r in rows) {
          map.putIfAbsent(r.source, () => []).add(r);
        }
        final keys = map.keys.toList()
          ..sort((a, b) {
            final c = _sourceGroupRank(a).compareTo(_sourceGroupRank(b));
            if (c != 0) return c;
            return a.compareTo(b);
          });
        final out = <Widget>[];
        for (final k in keys) {
          final list = map[k]!..sort(_compareCreatedDesc);
          final sample = list.first;
          out.add(_groupHeader(_sourceLabel(sample, loc)));
          for (var i = 0; i < list.length; i++) {
            if (i > 0) const SizedBox(height: 10);
            out.add(_transactionCard(context, list[i], loc, fmt));
          }
          out.add(const SizedBox(height: 8));
        }
        return out;
      case _LedgerGroupBy.property:
        final map = <String, List<TransactionModel>>{};
        for (final r in rows) {
          final pid = r.propertyId.isEmpty ? '—' : r.propertyId;
          map.putIfAbsent(pid, () => []).add(r);
        }
        final keys = map.keys.toList()
          ..sort((a, b) {
            final na = _propertyHeadline(map[a]!.first, loc);
            final nb = _propertyHeadline(map[b]!.first, loc);
            return na.compareTo(nb);
          });
        final out = <Widget>[];
        for (final k in keys) {
          final list = map[k]!..sort(_compareCreatedDesc);
          final headline = _propertyHeadline(list.first, loc);
          out.add(_groupHeader('${loc.adminLedgerPropertyNameLabel}: $headline'));
          for (var i = 0; i < list.length; i++) {
            if (i > 0) const SizedBox(height: 10);
            out.add(_transactionCard(context, list[i], loc, fmt));
          }
          out.add(const SizedBox(height: 8));
        }
        return out;
    }
  }

  Widget _transactionCard(
    BuildContext context,
    TransactionModel row,
    AppLocalizations loc,
    NumberFormat fmt,
  ) {
    final pending = row.payoutStatus == 'pending';
    final canRefund = row.isChaletDailyLedger &&
        row.refundStatus == 'none' &&
        pending &&
        !row.isFinalized &&
        row.status != 'refunded';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(
                        label: Text(
                          _sourceLabel(row, loc),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: AppColors.navy.withValues(alpha: 0.09),
                        side: BorderSide(color: AppColors.navy.withValues(alpha: 0.2)),
                      ),
                      if (row.hasAdminIntegrityWarnings)
                        Tooltip(
                          message: loc.adminLedgerIntegrityHint,
                          child: Icon(
                            Icons.warning_amber_rounded,
                            size: 22,
                            color: Colors.amber.shade800,
                          ),
                        ),
                    ],
                  ),
                ),
                Text(
                  pending
                      ? loc.chaletTransactionPayoutPending
                      : loc.chaletTransactionPayoutPaid,
                  style: TextStyle(
                    color: pending ? Colors.orange.shade800 : Colors.green.shade800,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _propertyHeadline(row, loc),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.navy,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${_referenceLabel(row, loc)}: ${row.referenceId.isEmpty ? '—' : row.referenceId}',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
            ),
            Text(
              '${loc.adminLedgerPropertyIdLabel}: ${row.propertyId.isEmpty ? '—' : row.propertyId}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            if (row.hasAdminIntegrityWarnings && !row.hasIssue) ...[
              const SizedBox(height: 10),
              Material(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: Colors.amber.shade900, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          loc.adminLedgerIntegrityHint,
                          style: TextStyle(
                            color: Colors.amber.shade900,
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (row.hasIssue) ...[
              const SizedBox(height: 10),
              Material(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, color: Colors.red.shade800),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              loc.adminChaletLedgerHasIssueBadge,
                              style: TextStyle(
                                color: Colors.red.shade900,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        loc.adminChaletPayoutNeedsReviewHint,
                        style: TextStyle(color: Colors.red.shade900, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (row.isFinalized) ...[
              const SizedBox(height: 10),
              Material(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, color: Colors.grey.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          loc.adminChaletLedgerFinalizedBadge,
                          style: TextStyle(
                            color: Colors.grey.shade900,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (row.integrityAmountMissingOrInvalid)
              _moneyRowTextValue(
                loc.chaletTransactionGrossLabel,
                '—',
                row.currency,
              )
            else
              _moneyRow(loc.chaletTransactionGrossLabel, row.amount, fmt, row.currency),
            _moneyRow(loc.chaletTransactionCommissionLabel, row.commissionAmount, fmt, row.currency),
            _moneyRow(loc.chaletTransactionPlatformRevenueLabel, row.platformRevenue, fmt, row.currency),
            _moneyRow(loc.chaletTransactionNetLabel, row.netAmount, fmt, row.currency),
            _moneyRow(loc.chaletTransactionOwnerPayoutLabel, row.ownerPayoutAmount, fmt, row.currency),
            const SizedBox(height: 4),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: Text(
                  loc.adminLedgerDetailsSection,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.person_outline_rounded, size: 18, color: Colors.grey.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          row.displayOwnerLabel(loc.adminChaletLedgerOwnerUnknown),
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                        ),
                      ),
                    ],
                  ),
                  if (row.ownerPhone.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(row.ownerPhone, style: TextStyle(fontSize: 13, color: Colors.grey.shade800)),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    'ownerId: ${row.ownerId}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  Text(
                    'status: ${row.status}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  Text(
                    '${loc.chaletTransactionPayoutStatusLabel}: ${row.payoutStatus}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  Text(
                    '${loc.chaletTransactionRefundStatusLabel}: ${row.refundStatus}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  Text(
                    '${loc.chaletTransactionRefundAmountLabel}: ${row.refundAmount.toStringAsFixed(3)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  if (row.refundReference != null && row.refundReference!.trim().isNotEmpty)
                    Text(
                      '${loc.chaletTransactionRefundReferenceLabel}: ${row.refundReference}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  Text(
                    '${loc.chaletTransactionPaymentVerifiedLabel}: ${row.paymentVerified}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  if (row.pricePerNight != null || (row.daysCount ?? 0) > 0)
                    Text(
                      '${row.pricePerNight?.toStringAsFixed(3) ?? '—'} × ${row.daysCount ?? 0}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                ],
              ),
            ),
            if (canRefund) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => _processRefund(context, row),
                child: Text(loc.adminChaletRefundExecute),
              ),
            ],
            if (row.isChaletDailyLedger &&
                pending &&
                !row.isFinalized &&
                !row.hasIssue &&
                row.ownerPayoutAmount > 0) ...[
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => _markPaid(context, row),
                child: Text(loc.adminChaletPayoutTransferToOwner),
              ),
            ],
            if (row.isChaletDailyLedger &&
                pending &&
                !row.isFinalized &&
                row.hasIssue &&
                row.ownerPayoutAmount > 0) ...[
              const SizedBox(height: 6),
              Text(
                loc.adminChaletPayoutBlockedHasIssueHint,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _markPaid(
    BuildContext context,
    TransactionModel row,
  ) async {
    final loc = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.adminChaletPayoutMarkPaidConfirmTitle),
        content: Text(
          '${loc.adminChaletPayoutMarkPaidConfirmBody}\n\n'
          '${loc.chaletTransactionOwnerPayoutLabel}: ${row.ownerPayoutAmount.toStringAsFixed(3)} ${row.currency}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.adminChaletPayoutMarkPaidConfirmYes),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    try {
      await ChaletBookingTransactionService.markPayoutPaid(
        transactionId: row.id,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.adminChaletPayoutSnackOk)),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${loc.adminChaletPayoutSnackErr} $e')),
      );
    }
  }

  Future<void> _processRefund(
    BuildContext context,
    TransactionModel row,
  ) async {
    final loc = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.adminChaletRefundConfirmTitle),
        content: Text(loc.adminChaletRefundConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.confirm),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    try {
      await ChaletBookingTransactionService.processRefund(
        transactionId: row.id,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.adminChaletRefundSnackOk)),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${loc.adminChaletRefundSnackErr} $e')),
      );
    }
  }

  double _sumPendingNet(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    var sum = 0.0;
    for (final doc in docs) {
      final row = TransactionModel.parse(doc.id, doc.data());
      if (row == null || row.isDeleted) continue;
      if (row.payoutStatus != 'pending') continue;
      if (!_sourceFilter.matches(row)) continue;
      sum += row.ownerPayoutAmount;
    }
    return sum;
  }

  Widget _analyticsCard({required Widget child}) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: child,
      ),
    );
  }

  Widget _analyticsSection(
    BuildContext context,
    AppLocalizations loc,
    AdminLedgerMonthAnalytics a,
  ) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');
    final monthTitle = DateFormat.yMMMM(
      Localizations.localeOf(context).toString(),
    ).format(DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (a.hitsClientLimit) ...[
          _analyticsCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Colors.amber.shade900, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    loc.adminLedgerAnalyticsLimitWarning(a.limit),
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.amber.shade900,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          loc.adminLedgerAnalyticsHeading,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: Colors.grey.shade900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          monthTitle,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 12),
        _analyticsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loc.adminLedgerAnalyticsRevenueTitle,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${fmt.format(a.totalPlatformRevenue)} KWD',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                loc.adminLedgerAnalyticsTransactionsLabel(a.transactionCount),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 10),
              Text(
                loc.adminLedgerAnalyticsVolumeTitle,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${fmt.format(a.totalVolume)} KWD',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade900,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          loc.adminLedgerAnalyticsSourceBreakdown,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: Colors.grey.shade800,
          ),
        ),
        const SizedBox(height: 8),
        Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _analyticsCard(
                    child: _analyticsSourceTile(
                      context,
                      loc.adminLedgerSourceChalet,
                      fmt.format(a.chaletRevenue),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _analyticsCard(
                    child: _analyticsSourceTile(
                      context,
                      loc.adminLedgerSourceSale,
                      fmt.format(a.saleRevenue),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _analyticsCard(
                    child: _analyticsSourceTile(
                      context,
                      loc.adminLedgerSourceRent,
                      fmt.format(a.rentRevenue),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _analyticsCard(
                    child: _analyticsSourceTile(
                      context,
                      loc.adminLedgerSourceOther,
                      fmt.format(a.otherRevenue),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _analyticsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loc.adminLedgerAnalyticsTopProperty,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 8),
              if (a.hasTopProperty) ...[
                Text(
                  a.topPropertyDisplayLabel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${fmt.format(a.topPropertyRevenue)} KWD',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${loc.adminLedgerPropertyIdLabel}: ${a.topPropertyId}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ] else
                Text(
                  loc.adminLedgerAnalyticsTopPropertyEmpty,
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          loc.adminLedgerAnalyticsDataNote,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.35),
        ),
        if (a.undatedRowsCount > 0) ...[
          const SizedBox(height: 6),
          Text(
            loc.adminLedgerAnalyticsUndatedNote(a.undatedRowsCount),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.35),
          ),
        ],
      ],
    );
  }

  Widget _analyticsSourceTile(BuildContext context, String label, String amountKwd) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade800,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$amountKwd KWD',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(AppLocalizations loc) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 56,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              loc.adminChaletPayoutsEmptyTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.navy,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              loc.adminChaletPayoutsEmptySubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade700,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => setState(
                () => _pendingPayoutsOnly = !_pendingPayoutsOnly,
              ),
              child: Text(loc.adminChaletPayoutsEmptyCta),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return FutureBuilder<bool>(
      future: AuthService.isAdmin(),
      builder: (context, gate) {
        if (gate.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.adminChaletPayoutsTitle)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (gate.data != true) {
          final isAr = Localizations.localeOf(context).languageCode == 'ar';
          return Scaffold(
            appBar: AppBar(title: Text(loc.adminChaletPayoutsTitle)),
            body: Center(
              child: Text(isAr ? 'غير مصرّح' : 'Not authorized'),
            ),
          );
        }

        final query = _pendingPayoutsOnly
            ? ChaletBookingTransactionService.adminBookingLedgerPendingPayoutsQuery()
            : ChaletBookingTransactionService.adminBookingLedgerQuery();

        return Scaffold(
          backgroundColor: const Color(0xFFF7F7F7),
          appBar: AppBar(
            title: Text(loc.adminChaletPayoutsTitle),
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Segment filter moved out of AppBar.actions so the page
              // title stays legible. Sits just below the title and above
              // the pending-total summary card.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(
                  alignment: Alignment.center,
                  child: SegmentedButton<bool>(
                    emptySelectionAllowed: false,
                    multiSelectionEnabled: false,
                    segments: [
                      ButtonSegment<bool>(
                        value: true,
                        label: Text(loc.adminChaletPayoutsFilterPending),
                      ),
                      ButtonSegment<bool>(
                        value: false,
                        label: Text(loc.adminChaletPayoutsFilterAll),
                      ),
                    ],
                    selected: {_pendingPayoutsOnly},
                    onSelectionChanged: (s) {
                      if (s.isEmpty) return;
                      setState(() => _pendingPayoutsOnly = s.first);
                    },
                  ),
                ),
              ),
              // Everything below the segment shares a single scroll
               // surface — otherwise the pending-total card + "this
               // month" analytics + filter dropdowns easily exceed the
               // viewport and the remaining `Expanded(ListView)` gets
               // squeezed to zero height, producing a RenderFlex
               // overflow at the bottom.
               Expanded(
                 child: ListView(
                   padding: EdgeInsets.zero,
                   children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: ChaletBookingTransactionService.adminBookingLedgerPendingPayoutsQuery()
                      .snapshots(),
                  builder: (context, pendingSnap) {
                    if (pendingSnap.hasError) {
                      return Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.red.shade200),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            '${pendingSnap.error}',
                            style: TextStyle(color: Colors.red.shade800),
                          ),
                        ),
                      );
                    }
                    final docs = pendingSnap.data?.docs ?? const [];
                    final total = _sumPendingNet(docs);
                    return Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: AppColors.navy.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(12),
                                child: Icon(
                                  Icons.payments_outlined,
                                  color: AppColors.navy,
                                  size: 28,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    loc.adminChaletPayoutsTotalPending,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade800,
                                      height: 1.3,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    '${total.toStringAsFixed(3)} KWD',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: ChaletBookingTransactionService.adminBookingLedgerQuery()
                      .snapshots(),
                  builder: (context, analyticsSnap) {
                    if (analyticsSnap.hasError) {
                      return const SizedBox.shrink();
                    }
                    if (analyticsSnap.connectionState == ConnectionState.waiting &&
                        !analyticsSnap.hasData) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: const LinearProgressIndicator(minHeight: 3),
                        ),
                      );
                    }
                    final a = AdminLedgerMonthAnalytics.fromDocuments(
                      analyticsSnap.data?.docs ?? const [],
                      unknownPropertyLabel: loc.adminLedgerUnknownProperty,
                      limit: ChaletBookingTransactionService.adminBookingLedgerPageSizeDefault,
                    );
                    return _analyticsSection(context, loc, a);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      loc.adminLedgerFilterSourceLabel,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<_SourceFilter>(
                          value: _sourceFilter,
                          isExpanded: true,
                          items: _SourceFilter.values
                              .map(
                                (f) => DropdownMenuItem(
                                  value: f,
                                  child: Text(f.title(loc)),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _sourceFilter = v);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      loc.adminLedgerGroupByLabel,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<_LedgerGroupBy>(
                          value: _groupBy,
                          isExpanded: true,
                          items: _LedgerGroupBy.values
                              .map(
                                (g) => DropdownMenuItem(
                                  value: g,
                                  child: Text(g.title(loc)),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _groupBy = v);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Transaction list lives inside the outer scroll (parent
              // ListView above). We therefore render its children
              // inline as a non-scrolling `Column` instead of a nested
              // ListView — this avoids double-scroll jank and is the
               // only way to keep the analytics + list scrolling as one
               // coherent surface.
               StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                 stream: query.snapshots(),
                 builder: (context, snap) {
                    if (snap.hasError) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        child: Center(child: Text('${snap.error}')),
                      );
                    }
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final docs = snap.data?.docs ?? const [];
                    final rows = <TransactionModel>[];
                    for (final d in docs) {
                      final row = TransactionModel.parse(d.id, d.data());
                      if (row == null || row.isDeleted) continue;
                      if (!_sourceFilter.matches(row)) continue;
                      rows.add(row);
                    }
                    if (rows.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: _buildEmptyState(loc),
                      );
                    }

                    final children = _buildGroupedList(context, rows, loc);

                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: children,
                      ),
                    );
                  },
                ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
