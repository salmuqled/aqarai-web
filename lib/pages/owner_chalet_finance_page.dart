import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/chalet_booking_transaction.dart';
import 'package:aqarai_app/services/chalet_booking_transaction_service.dart';

/// Owner read-only: chalet booking net earnings from `transactions`.
class OwnerChaletFinancePage extends StatelessWidget {
  const OwnerChaletFinancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final fmt = NumberFormat.decimalPattern();

    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: Text(loc.ownerChaletFinanceTitle)),
        body: const Center(child: Text('—')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(loc.ownerChaletFinanceTitle)),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream:
            ChaletBookingTransactionService.ownerChaletDailyQuery(uid).snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data?.docs ?? const [];
          var netSum = 0.0;
          var commSum = 0.0;
          final rows = <ChaletBookingTransaction>[];
          for (final d in docs) {
            final row = TransactionModel.parse(d.id, d.data());
            if (row == null || row.isDeleted) continue;
            rows.add(row);
            netSum += row.ownerPayoutAmount;
            commSum += row.commissionAmount;
          }
          final currency = rows.isEmpty ? 'KWD' : rows.first.currency;

          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.ownerChaletFinanceSubtitle,
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      const SizedBox(height: 16),
                      _statRow(loc.ownerChaletFinanceBookingsCount, '${rows.length}'),
                      const SizedBox(height: 8),
                      _statRow(
                        loc.ownerChaletFinanceNetTotal,
                        '${fmt.format(netSum)} $currency',
                      ),
                      const SizedBox(height: 8),
                      _statRow(
                        loc.ownerChaletFinanceCommissionTotal,
                        '${fmt.format(commSum)} $currency',
                      ),
                    ],
                  ),
                ),
              ),
              if (rows.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text(loc.ownerChaletFinanceEmpty)),
                )
              else
                SliverList.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    final pending = row.payoutStatus == 'pending';
                    final ledgerNotes = <String>[];
                    if (row.isFinalized) ledgerNotes.add(loc.adminChaletLedgerFinalizedBadge);
                    if (row.hasIssue) ledgerNotes.add(loc.adminChaletLedgerHasIssueBadge);
                    final ledgerSuffix =
                        ledgerNotes.isEmpty ? '' : '\n${ledgerNotes.join(' · ')}';
                    return ListTile(
                      title: Text(
                        pending
                            ? loc.chaletTransactionPayoutPending
                            : loc.chaletTransactionPayoutPaid,
                      ),
                      subtitle: Text(
                        'booking ${row.bookingId}\n'
                        '${loc.chaletTransactionPayoutStatusLabel}: ${row.payoutStatus}\n'
                        '${loc.chaletTransactionOwnerPayoutLabel}: ${row.ownerPayoutAmount.toStringAsFixed(3)}\n'
                        '${loc.chaletTransactionRefundStatusLabel}: ${row.refundStatus} · '
                        '${loc.chaletTransactionRefundAmountLabel}: ${row.refundAmount.toStringAsFixed(3)}'
                        '$ledgerSuffix',
                      ),
                      isThreeLine: true,
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  static Widget _statRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        Flexible(
          child: Text(value, textAlign: TextAlign.end),
        ),
      ],
    );
  }
}
