import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/chalet_booking_transaction.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/chalet_booking_transaction_service.dart';

/// Admin: chalet booking ledger + manual payout after bank transfer.
class AdminChaletPayoutsPage extends StatefulWidget {
  const AdminChaletPayoutsPage({super.key});

  @override
  State<AdminChaletPayoutsPage> createState() => _AdminChaletPayoutsPageState();
}

class _AdminChaletPayoutsPageState extends State<AdminChaletPayoutsPage> {
  /// Default: payout queue only (`payoutStatus == pending`).
  bool _pendingPayoutsOnly = true;

  Future<void> _markPaid(
    BuildContext context,
    ChaletBookingTransaction row,
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
    ChaletBookingTransaction row,
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
      final row = ChaletBookingTransaction.tryParse(doc.id, doc.data());
      if (row == null || row.isDeleted) continue;
      if (row.payoutStatus != 'pending') continue;
      sum += row.ownerPayoutAmount;
    }
    return sum;
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
            ? ChaletBookingTransactionService.adminChaletDailyPendingPayoutsQuery()
            : ChaletBookingTransactionService.adminChaletDailyQuery();

        return Scaffold(
          appBar: AppBar(
            title: Text(loc.adminChaletPayoutsTitle),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
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
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: ChaletBookingTransactionService.adminChaletDailyPendingPayoutsQuery()
                    .snapshots(),
                builder: (context, pendingSnap) {
                  if (pendingSnap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('${pendingSnap.error}', style: TextStyle(color: Colors.red.shade800)),
                    );
                  }
                  final docs = pendingSnap.data?.docs ?? const [];
                  final total = _sumPendingNet(docs);
                  return Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              loc.adminChaletPayoutsTotalPending,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Text(
                            '${total.toStringAsFixed(3)} KWD',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: query.snapshots(),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(child: Text('${snap.error}'));
                    }
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snap.data?.docs ?? const [];
                    final rows = <ChaletBookingTransaction>[];
                    for (final d in docs) {
                      final row = ChaletBookingTransaction.tryParse(d.id, d.data());
                      if (row == null || row.isDeleted) continue;
                      rows.add(row);
                    }
                    if (rows.isEmpty) {
                      return Center(child: Text(loc.ownerChaletFinanceEmpty));
                    }

                    return ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final row = rows[i];
                        final pending = row.payoutStatus == 'pending';
                        final canRefund = row.refundStatus == 'none' &&
                            pending &&
                            !row.isFinalized &&
                            row.status != 'refunded';

                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pending
                                      ? loc.chaletTransactionPayoutPending
                                      : loc.chaletTransactionPayoutPaid,
                                  style: TextStyle(
                                    color: pending ? Colors.orange.shade800 : Colors.green.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (row.hasIssue) ...[
                                  const SizedBox(height: 8),
                                  Material(
                                    color: Colors.red.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
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
                                            style: TextStyle(
                                              color: Colors.red.shade900,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                if (row.isFinalized) ...[
                                  const SizedBox(height: 8),
                                  Material(
                                    color: Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
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
                                const SizedBox(height: 8),
                                Text('propertyId: ${row.propertyId}'),
                                Text('bookingId: ${row.bookingId}'),
                                Text(
                                  '👤 ${row.displayOwnerLabel(loc.adminChaletLedgerOwnerUnknown)}',
                                ),
                                if (row.ownerPhone.isNotEmpty) Text('📞 ${row.ownerPhone}'),
                                Text(
                                  'ownerId: ${row.ownerId}',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                ),
                                Text('status: ${row.status}'),
                                Text(
                                  '${loc.chaletTransactionPayoutStatusLabel}: ${row.payoutStatus}',
                                ),
                                Text(
                                  '${loc.chaletTransactionNetLabel}: ${row.netAmount.toStringAsFixed(3)}',
                                ),
                                Text(
                                  '${loc.chaletTransactionOwnerPayoutLabel}: ${row.ownerPayoutAmount.toStringAsFixed(3)}',
                                ),
                                Text(
                                  '${loc.chaletTransactionCommissionLabel}: ${row.commissionAmount.toStringAsFixed(3)}',
                                ),
                                Text(
                                  '${loc.chaletTransactionPlatformRevenueLabel}: ${row.platformRevenue.toStringAsFixed(3)}',
                                ),
                                Text(
                                  '${loc.chaletTransactionRefundStatusLabel}: ${row.refundStatus}',
                                ),
                                Text(
                                  '${loc.chaletTransactionRefundAmountLabel}: ${row.refundAmount.toStringAsFixed(3)}',
                                ),
                                if (row.refundReference != null &&
                                    row.refundReference!.trim().isNotEmpty)
                                  Text(
                                    '${loc.chaletTransactionRefundReferenceLabel}: ${row.refundReference}',
                                  ),
                                Text(
                                  '${loc.chaletTransactionPaymentVerifiedLabel}: ${row.paymentVerified}',
                                ),
                                if (row.bookingSnapshot != null) ...[
                                  if (row.bookingSnapshot!.propertyTitle != null &&
                                      row.bookingSnapshot!.propertyTitle!.isNotEmpty)
                                    Text('title: ${row.bookingSnapshot!.propertyTitle}'),
                                ],
                                if (row.pricePerNight != null || (row.daysCount ?? 0) > 0)
                                  Text(
                                    'snapshot: ${row.pricePerNight?.toStringAsFixed(3) ?? '—'} × ${row.daysCount ?? 0} nights',
                                  ),
                                if (canRefund) ...[
                                  const SizedBox(height: 10),
                                  OutlinedButton(
                                    onPressed: () => _processRefund(context, row),
                                    child: Text(loc.adminChaletRefundExecute),
                                  ),
                                ],
                                if (pending &&
                                    !row.isFinalized &&
                                    !row.hasIssue &&
                                    row.ownerPayoutAmount > 0) ...[
                                  const SizedBox(height: 10),
                                  FilledButton(
                                    onPressed: () => _markPaid(context, row),
                                    child: Text(loc.adminChaletPayoutTransferToOwner),
                                  ),
                                ],
                                if (pending &&
                                    !row.isFinalized &&
                                    row.hasIssue &&
                                    row.ownerPayoutAmount > 0) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    loc.adminChaletPayoutBlockedHasIssueHint,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
