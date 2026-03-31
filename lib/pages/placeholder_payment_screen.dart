import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auction/auction_deposit.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/services/auction/deposit_service.dart';

/// Post-checkout: reflects real deposit status via Firestore (verifying → paid).
/// Reserved for MyFatoorah (or other gateway) WebView / deep link return.
class PlaceholderPaymentScreen extends StatelessWidget {
  const PlaceholderPaymentScreen({
    super.key,
    this.auctionId,
    this.lotId,
  });

  final String? auctionId;
  final String? lotId;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final user = FirebaseAuth.instance.currentUser;
    final lotId = this.lotId;

    if (user == null || lotId == null || lotId.isEmpty) {
      return _StaticPlaceholder(loc: loc);
    }

    return StreamBuilder<AuctionDeposit?>(
      stream: DepositService.watchDeposit(userId: user.uid, lotId: lotId),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.auctionDepositTitle)),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snap.error}', textAlign: TextAlign.center),
              ),
            ),
          );
        }

        final dep = snap.data;
        final pending =
            dep != null && dep.paymentStatus == DepositPaymentStatus.pending;
        final paid = dep?.isPaid == true;

        if (paid && dep != null) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.auctionDepositTitle)),
            body: _PaidDepositBody(key: ValueKey<String>(dep.id), loc: loc),
          );
        }

        if (pending || snap.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.auctionDepositTitle)),
            body: _VerifyingBody(loc: loc),
          );
        }

        // No row yet (rare) — same as initial placeholder.
        return _StaticPlaceholder(loc: loc);
      },
    );
  }
}

class _StaticPlaceholder extends StatelessWidget {
  const _StaticPlaceholder({required this.loc});

  final AppLocalizations loc;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(loc.auctionDepositTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                loc.auctionDepositRedirecting,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                loc.auctionDepositGatewayPlaceholderHint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VerifyingBody extends StatelessWidget {
  const _VerifyingBody({required this.loc});

  final AppLocalizations loc;

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 28),
              Text(
                loc.auctionDepositVerifyingPayment,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaidDepositBody extends StatelessWidget {
  const _PaidDepositBody({super.key, required this.loc});

  final AppLocalizations loc;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 650),
                    curve: Curves.elasticOut,
                    builder: (context, t, child) =>
                        Transform.scale(scale: t, child: child),
                    child: Icon(
                      Icons.verified_rounded,
                      size: 88,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    loc.auctionDepositReceivedSuccess,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    loc.auctionRegFullyRegistered,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(loc.auctionDepositPaymentDone),
            ),
          ],
        ),
      ),
    );
  }
}
