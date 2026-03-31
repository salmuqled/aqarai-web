import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/pages/placeholder_payment_screen.dart';
import 'package:aqarai_app/services/auction/deposit_service.dart';

/// Creates pending deposit then hands off to [PlaceholderPaymentScreen] (gateway TBD).
class AuctionDepositPaymentPage extends StatefulWidget {
  const AuctionDepositPaymentPage({
    super.key,
    required this.auctionId,
    required this.lotId,
    required this.depositType,
    required this.depositValue,
    required this.listingPrice,
  });

  final String auctionId;
  final String lotId;
  final DepositType depositType;
  final double depositValue;
  final double listingPrice;

  @override
  State<AuctionDepositPaymentPage> createState() =>
      _AuctionDepositPaymentPageState();
}

class _AuctionDepositPaymentPageState extends State<AuctionDepositPaymentPage> {
  bool _isSubmitting = false;

  double _amountDue(AppLocalizations loc) {
    if (widget.depositType == DepositType.percentage) {
      if (widget.listingPrice <= 0) return 0;
      return widget.listingPrice * widget.depositValue / 100.0;
    }
    return widget.depositValue;
  }

  String _formatMoney(BuildContext context, double value) {
    final locale = Localizations.localeOf(context).toString();
    final fmt = NumberFormat.currency(
      locale: locale,
      symbol: '',
      decimalDigits: value == value.roundToDouble() ? 0 : 3,
    );
    final suffix = Localizations.localeOf(context).languageCode == 'ar'
        ? ' د.ك'
        : ' KWD';
    return '${fmt.format(value)}$suffix';
  }

  Future<void> _onContinue(AppLocalizations loc) async {
    if (_isSubmitting) return;
    final due = _amountDue(loc);
    if (due <= 0) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _isSubmitting = true);
    try {
      await DepositService.createAuctionDeposit(
        auctionId: widget.auctionId,
        lotId: widget.lotId,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
          builder: (_) => PlaceholderPaymentScreen(
            auctionId: widget.auctionId,
            lotId: widget.lotId,
          ),
        ),
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
    final due = _amountDue(loc);
    final invalidPercent =
        widget.depositType == DepositType.percentage && widget.listingPrice <= 0;

    return Scaffold(
      appBar: AppBar(title: Text(loc.auctionDepositTitle)),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (invalidPercent)
                  Card(
                    color: Colors.orange.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(loc.auctionDepositListingPriceMissing),
                    ),
                  )
                else ...[
                  Text(
                    loc.auctionDepositAmountLabel,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _formatMoney(context, due),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (widget.depositType == DepositType.percentage) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${widget.depositValue.toStringAsFixed(widget.depositValue == widget.depositValue.roundToDouble() ? 0 : 2)}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
                const Spacer(),
                FilledButton(
                  onPressed: invalidPercent || due <= 0 || _isSubmitting
                      ? null
                      : () => _onContinue(loc),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(loc.auctionDepositContinue),
                ),
              ],
            ),
          ),
          if (_isSubmitting)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(
                  child: Card(
                    margin: const EdgeInsets.all(32),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(
                            loc.auctionDepositRedirecting,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
