import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/auth/login_page.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/public_auction_lot.dart';
import 'package:aqarai_app/pages/auction_deposit_payment_page.dart';
import 'package:aqarai_app/services/auction/auction_registration_stream.dart';
import 'package:aqarai_app/services/auction/auction_service.dart';

/// Shows auction registration / deposit state for a listing linked to [lot].
class AuctionRegistrationStatusWidget extends StatefulWidget {
  const AuctionRegistrationStatusWidget({
    super.key,
    required this.lot,
    required this.listingPrice,
  });

  final PublicAuctionLot lot;
  final double listingPrice;

  @override
  State<AuctionRegistrationStatusWidget> createState() =>
      _AuctionRegistrationStatusWidgetState();
}

class _AuctionRegistrationStatusWidgetState
    extends State<AuctionRegistrationStatusWidget> {
  bool _isSubmitting = false;

  static const Color _green = Color(0xFF15803D);
  static const Color _yellow = Color(0xFFB45309);
  static const Color _red = Color(0xFFB91C1C);
  static const Color _blue = Color(0xFF2563EB);

  PublicAuctionLot get lot => widget.lot;
  double get listingPrice => widget.listingPrice;

  Future<void> _onRegisterPressed(String userId) async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      await AuctionService.createParticipant(
        userId: userId,
        auctionId: lot.auctionId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return _shell(
        context,
        border: _blue,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              loc.auctionRegLoginToRegister,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _blue),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LoginPage()),
                );
              },
              child: Text(loc.auctionRegLoginToRegister),
            ),
          ],
        ),
      );
    }

    return StreamBuilder<AuctionRegistrationSnapshot>(
      stream: watchAuctionRegistration(
        userId: user.uid,
        auctionId: lot.auctionId,
        lotId: lot.id,
      ),
      builder: (context, snap) {
        if (snap.hasError) {
          return _shell(
            context,
            border: _red,
            child: Text('${snap.error}', style: const TextStyle(color: _red)),
          );
        }

        final data = snap.data;
        if (data == null || !data.ready) {
          return _shell(
            context,
            border: Colors.grey.shade400,
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    loc.auctionRegLoading,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          );
        }

        final p = data.participant;

        if (p == null) {
          return _shell(
            context,
            border: _blue,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  loc.auctionRegRegisterButton,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _blue),
                  onPressed: _isSubmitting ? null : () => _onRegisterPressed(user.uid),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(loc.auctionRegRegisterButton),
                ),
              ],
            ),
          );
        }

        switch (p.status) {
          case ParticipantStatus.pending:
            return _shell(
              context,
              border: _yellow,
              background: Colors.amber.shade50,
              child: Text(
                loc.auctionRegPendingReview,
                style: const TextStyle(
                  color: Color(0xFF92400E),
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          case ParticipantStatus.rejected:
            return _shell(
              context,
              border: _red,
              background: Colors.red.shade50,
              child: Text(
                loc.auctionRegRejected,
                style: const TextStyle(
                  color: _red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          case ParticipantStatus.blocked:
            return _shell(
              context,
              border: _red,
              background: Colors.red.shade50,
              child: Text(
                loc.auctionRegBlocked,
                style: const TextStyle(
                  color: _red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          case ParticipantStatus.approved:
            break;
        }

        final dep = data.deposit;
        final paid = dep?.isPaid == true;
        final depositPending =
            dep != null && dep.paymentStatus == DepositPaymentStatus.pending;

        if (depositPending) {
          return _shell(
            context,
            border: _blue,
            background: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
            child: AbsorbPointer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: _blue,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          loc.auctionDepositVerifyingPayment,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: _blue,
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        if (!paid) {
          return _shell(
            context,
            border: _blue,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  loc.auctionRegPayDeposit,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _blue),
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => AuctionDepositPaymentPage(
                          auctionId: lot.auctionId,
                          lotId: lot.id,
                          depositType: lot.depositType,
                          depositValue: lot.depositValue,
                          listingPrice: listingPrice,
                        ),
                      ),
                    );
                  },
                  child: Text(loc.auctionRegPayDeposit),
                ),
              ],
            ),
          );
        }

        return _shell(
          context,
          border: _green,
          background: Colors.green.shade50,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.check_circle, color: _green),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      loc.auctionRegFullyRegistered,
                      style: const TextStyle(
                        color: _green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                loc.auctionDepositReceivedSuccess,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _green.withValues(alpha: 0.9),
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _shell(
    BuildContext context, {
    required Color border,
    Color? background,
    required Widget child,
  }) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Card(
        key: ValueKey<String>('${lot.id}_$border'),
        elevation: 0,
        color: background ?? Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: child,
        ),
      ),
    );
  }
}
