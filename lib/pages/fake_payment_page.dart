import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// QA-only UI: simulate gateway success / failure without MyFatoorah WebView.
///
/// Returns `true` if user taps success, `false` if failure or back without success.
class FakePaymentPage extends StatelessWidget {
  const FakePaymentPage({
    super.key,
    required this.totalPrice,
    required this.currencyCode,
    required this.isAr,
  });

  final double totalPrice;
  final String currencyCode;
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');
    final totalLabel = '${fmt.format(totalPrice)} $currencyCode';

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'محاكاة الدفع' : 'Payment simulation'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isAr ? 'المبلغ الإجمالي' : 'Total',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              totalLabel,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.check_circle_outline),
              label: Text(
                isAr ? 'نجاح الدفع \u2714\uFE0F' : 'Payment success \u2714\uFE0F',
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(false),
              icon: const Icon(Icons.cancel_outlined),
              label: Text(
                isAr ? 'فشل الدفع \u274C' : 'Payment failed \u274C',
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
