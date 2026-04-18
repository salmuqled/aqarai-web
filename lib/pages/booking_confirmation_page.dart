import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/pages/booking_myfatoorah_webview_page.dart';
import 'package:aqarai_app/pages/booking_success_page.dart';
import 'package:aqarai_app/services/chalet_booking_service.dart';

class BookingConfirmationPage extends StatefulWidget {
  const BookingConfirmationPage({
    super.key,
    required this.bookingId,
    required this.propertyId,
    required this.propertyTitle,
    required this.imageUrl,
    required this.startDate,
    required this.endDate,
    required this.nights,
    required this.pricePerNight,
    required this.totalPrice,
  });

  final String bookingId;
  final String propertyId;
  final String propertyTitle;
  final String imageUrl;
  final DateTime startDate;
  final DateTime endDate;
  final int nights;
  final double pricePerNight;
  final double totalPrice;

  @override
  State<BookingConfirmationPage> createState() => _BookingConfirmationPageState();
}

class _BookingConfirmationPageState extends State<BookingConfirmationPage> {
  bool _loading = false;

  bool get _isAr => Localizations.localeOf(context).languageCode == 'ar';

  String get _currencyLabel => _isAr ? 'د.ك' : 'KWD';

  Future<void> _payNow() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final outcome =
          await ChaletBookingService.submitChaletBookingConfirmationPayment(
        bookingId: widget.bookingId,
        lang: _isAr ? 'ar' : 'en',
      );
      if (!mounted) return;

      switch (outcome.status) {
        case ChaletBookingPayNowStatus.failed:
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                outcome.errorMessage ??
                    (_isAr ? 'تعذر إتمام الدفع' : 'Could not complete payment'),
              ),
            ),
          );
          return;
        case ChaletBookingPayNowStatus.myfatoorahSessionStarted:
          setState(() => _loading = false);
          final payUrl = outcome.paymentUrl?.trim() ?? '';
          final payId = outcome.paymentId?.trim() ?? '';
          if (payUrl.isEmpty || payId.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text(
                  _isAr ? 'جلسة الدفع غير صالحة' : 'Invalid payment session',
                ),
              ),
            );
            return;
          }

          final paid = await Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (_) => BookingMyFatoorahWebViewPage(
                paymentUrl: payUrl,
                bookingId: widget.bookingId,
                paymentId: payId,
                isAr: _isAr,
              ),
            ),
          );
          if (!mounted) return;

          if (paid == true) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text(
                  _isAr
                      ? 'تم الدفع وتأكيد الحجز 🎉'
                      : 'Payment complete — booking confirmed 🎉',
                ),
              ),
            );

            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute<void>(
                builder: (_) => BookingSuccessPage(
                  propertyId: widget.propertyId,
                  startDate: widget.startDate,
                  endDate: widget.endDate,
                  totalDays: widget.nights,
                  totalPrice: widget.totalPrice,
                  currencyCode: _currencyLabel,
                  bookingId: widget.bookingId,
                  confirmedAfterPayment: true,
                ),
              ),
              (route) => route.isFirst,
            );
            return;
          }

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                _isAr
                    ? 'لم يكتمل الدفع. يمكنك المحاولة مرة أخرى.'
                    : 'Payment was not completed. You can try again.',
              ),
            ),
          );
          return;
        case ChaletBookingPayNowStatus.fakeSucceeded:
          break;
      }

      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'تم الدفع بنجاح' : 'Payment successful'),
        ),
      );

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => BookingSuccessPage(
            propertyId: widget.propertyId,
            startDate: widget.startDate,
            endDate: widget.endDate,
            totalDays: widget.nights,
            totalPrice: widget.totalPrice,
            currencyCode: _currencyLabel,
            bookingId: widget.bookingId,
            confirmedAfterPayment: true,
          ),
        ),
        (route) => route.isFirst,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'حدث خطأ غير متوقع' : 'Unexpected error'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = NumberFormat.decimalPattern(_isAr ? 'ar' : 'en');
    final dateFmt = DateFormat.yMMMd(_isAr ? 'ar' : 'en_US');

    final totalLabel = '${fmt.format(widget.totalPrice)} $_currencyLabel';
    final perNightLabel = '${fmt.format(widget.pricePerNight)} $_currencyLabel';
    final rangeLabel =
        '${dateFmt.format(widget.startDate)} → ${dateFmt.format(widget.endDate)}';

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        title: Text(_isAr ? 'تأكيد الحجز' : 'Confirm booking'),
        centerTitle: true,
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _loading ? null : _payNow,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: _loading
                ? SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: cs.onPrimary,
                    ),
                  )
                : Text(
                    _isAr ? 'ادفع الآن - $totalLabel' : 'Pay now - $totalLabel',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: widget.imageUrl.trim().isEmpty
                  ? Container(color: Colors.grey.shade300)
                  : Image.network(
                      widget.imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, __) =>
                          Container(color: Colors.grey.shade300),
                      loadingBuilder: (context, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          color: Colors.grey.shade200,
                          alignment: Alignment.center,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              cs.primary.withValues(alpha: 0.8),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.propertyTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          _InfoCard(
            children: [
              _InfoRow(
                label: _isAr ? 'التواريخ' : 'Dates',
                value: rangeLabel,
              ),
              const SizedBox(height: 10),
              _InfoRow(
                label: _isAr ? 'عدد الليالي' : 'Nights',
                value: '${widget.nights}',
              ),
              const SizedBox(height: 10),
              _InfoRow(
                label: _isAr ? 'سعر الليلة' : 'Price / night',
                value: perNightLabel,
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: cs.outline.withValues(alpha: 0.14)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _isAr ? 'الإجمالي' : 'Total',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    totalLabel,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: cs.primary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.62),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

