import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:aqarai_app/services/payment/mark_auction_fee_paid_service.dart';
import 'package:aqarai_app/services/payment/payment_service_provider.dart';
import 'package:aqarai_app/services/auction/auction_request_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

/// Checkout screen for auction listing fee (mock gateway now; same UX for MyFatoorah later).
class AuctionPaymentPage extends StatefulWidget {
  const AuctionPaymentPage({
    super.key,
    required this.requestId,
    required this.auctionFeeKwd,
  });

  final String requestId;
  final double auctionFeeKwd;

  @override
  State<AuctionPaymentPage> createState() => _AuctionPaymentPageState();
}

class _AuctionPaymentPageState extends State<AuctionPaymentPage> {
  bool _processing = false;

  Future<void> _pay(AppLocalizations loc) async {
    if (_processing) return;
    setState(() => _processing = true);
    try {
      final uiOk = await PaymentServiceProvider.instance.payAuctionFee(
        amount: widget.auctionFeeKwd,
        requestId: widget.requestId,
      );
      if (!uiOk) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(loc.auctionPaymentDeclined)),
          );
        }
        return;
      }

      final result = await MarkAuctionFeePaidService.call(
        requestId: widget.requestId,
      );
      if (!mounted) return;
      if (!result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.auctionPaymentServerError)),
        );
        return;
      }
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
          builder: (_) => AuctionFeePaymentSuccessPage(
            paymentReference: result.paymentReference,
          ),
        ),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final msg = _mapFunctionsError(loc, e);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.auctionPaymentServerError)),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  String _mapFunctionsError(
    AppLocalizations loc,
    FirebaseFunctionsException e,
  ) {
    switch (e.code) {
      case 'permission-denied':
        return loc.auctionPaymentNotOwner;
      case 'not-found':
        return loc.auctionPaymentRequestMissing;
      case 'failed-precondition':
        return loc.auctionPaymentAlreadyProcessed;
      case 'unauthenticated':
        return loc.auctionPaymentSignInRequired;
      default:
        return loc.auctionPaymentServerError;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: Text(loc.auctionPaymentTitle)),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: AuctionRequestService.streamRequest(widget.requestId),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text(loc.auctionPaymentLoadError));
          }
          if (!snap.hasData || !snap.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data!.data() ?? {};
          final owner = data['userId']?.toString() ?? '';
          if (uid == null || owner != uid) {
            return Center(child: Text(loc.auctionPaymentNotOwner));
          }
          final status = data['auctionFeeStatus']?.toString() ?? 'pending';
          if (status == 'paid') {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement<void, void>(
                MaterialPageRoute<void>(
                  builder: (_) => AuctionFeePaymentSuccessPage(
                    paymentReference: data['paymentReference']?.toString(),
                  ),
                ),
              );
            });
            return const Center(child: CircularProgressIndicator());
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  loc.auctionPaymentFeeLine(
                    widget.auctionFeeKwd == widget.auctionFeeKwd.roundToDouble()
                        ? widget.auctionFeeKwd.toStringAsFixed(0)
                        : widget.auctionFeeKwd.toString(),
                  ),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  loc.auctionPaymentDescription,
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                if (_processing)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                FilledButton(
                  onPressed: _processing ? null : () => _pay(loc),
                  child: Text(loc.auctionPaymentPayNow),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Shown after successful server-side fee confirmation.
class AuctionFeePaymentSuccessPage extends StatelessWidget {
  const AuctionFeePaymentSuccessPage({
    super.key,
    this.paymentReference,
  });

  final String? paymentReference;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(loc.auctionPaymentSuccessTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.check_circle,
              color: theme.colorScheme.primary,
              size: 64,
            ),
            const SizedBox(height: 24),
            Text(
              loc.auctionPaymentSuccessMessage,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (paymentReference != null && paymentReference!.isNotEmpty) ...[
              const SizedBox(height: 16),
              SelectableText(
                '${loc.auctionPaymentReferenceLabel}: $paymentReference',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const Spacer(),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(loc.auctionPaymentDone),
            ),
          ],
        ),
      ),
    );
  }
}
