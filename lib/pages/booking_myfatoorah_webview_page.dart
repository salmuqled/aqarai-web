import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:aqarai_app/services/chalet_booking_service.dart';

/// In-app MyFatoorah checkout. Intercepts `aqarai://payment/...` redirects from gateway.
///
/// Backend callback URL shape (see `chalet_booking_payment_myfatoorah.ts`):
/// `aqarai://payment/success?bookingId=...` — [paymentId] is taken from the session when absent in the URL.
class BookingMyFatoorahWebViewPage extends StatefulWidget {
  const BookingMyFatoorahWebViewPage({
    super.key,
    required this.paymentUrl,
    required this.bookingId,
    required this.paymentId,
    required this.isAr,
  });

  final String paymentUrl;
  final String bookingId;
  final String paymentId;
  final bool isAr;

  @override
  State<BookingMyFatoorahWebViewPage> createState() =>
      _BookingMyFatoorahWebViewPageState();
}

class _BookingMyFatoorahWebViewPageState extends State<BookingMyFatoorahWebViewPage> {
  late final WebViewController _controller;
  var _pageLoading = true;
  var _verifying = false;
  var _handled = false;

  @override
  void initState() {
    super.initState();
    debugPrint(
      'PAYMENT_WEBVIEW_OPENED bookingId=${widget.bookingId} paymentId=${widget.paymentId}',
    );

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _pageLoading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _pageLoading = false);
          },
          onNavigationRequest: (NavigationRequest request) {
            final url = request.url;
            if (url.toLowerCase().startsWith('aqarai://')) {
              unawaited(_handleDeepLink(url));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.paymentUrl));
  }

  Future<void> _handleDeepLink(String url) async {
    if (_handled) return;
    final lower = url.toLowerCase();

    if (lower.contains('aqarai://payment/success')) {
      debugPrint('PAYMENT_SUCCESS_DETECTED url=$url');
      final uri = Uri.tryParse(url);
      final bidFromUrl = uri?.queryParameters['bookingId']?.trim();
      final pidFromUrl = uri?.queryParameters['paymentId']?.trim();

      final bookingIdToVerify =
          (bidFromUrl != null && bidFromUrl.isNotEmpty) ? bidFromUrl : widget.bookingId;
      final paymentIdToVerify =
          (pidFromUrl != null && pidFromUrl.isNotEmpty) ? pidFromUrl : widget.paymentId;

      if (bookingIdToVerify != widget.bookingId) {
        debugPrint('PAYMENT_FAILED reason=bookingId_mismatch');
        _handled = true;
        if (mounted) Navigator.of(context).pop(false);
        return;
      }

      _handled = true;
      if (mounted) setState(() => _verifying = true);

      final v = await ChaletBookingService.verifyBookingMyFatoorahPayment(
        bookingId: bookingIdToVerify,
        paymentId: paymentIdToVerify,
      );

      if (!mounted) return;

      if (v.ok) {
        debugPrint('PAYMENT_VERIFIED bookingId=$bookingIdToVerify');
        Navigator.of(context).pop(true);
        return;
      }

      debugPrint(
        'PAYMENT_FAILED reason=verify_failed msg=${v.errorMessage ?? ''}',
      );
      Navigator.of(context).pop(false);
      return;
    }

    if (lower.contains('aqarai://payment/error')) {
      debugPrint('PAYMENT_FAILED reason=gateway_error_redirect url=$url');
      _handled = true;
      if (mounted) Navigator.of(context).pop(false);
    }
  }

  Future<void> _onClosePressed() async {
    if (_handled) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          widget.isAr
              ? '\u0625\u0644\u063a\u0627\u0621 \u0627\u0644\u062f\u0641\u0639\u061f'
              : 'Cancel payment?',
        ),
        content: Text(
          widget.isAr
              ? 'إذا غادرت الآن، سيتم إلغاء الحجز ما دام لم يكتمل الدفع.'
              : 'If you leave now, the booking will be cancelled unless payment completes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(widget.isAr ? 'متابعة الدفع' : 'Continue'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(widget.isAr ? 'إلغاء' : 'Cancel'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _handled = true;
    debugPrint('PAYMENT_FAILED reason=user_cancelled_webview');
    await ChaletBookingService.cancelBookingPendingPayment(
      bookingId: widget.bookingId,
    );
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        await _onClosePressed();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.isAr ? 'الدفع' : 'Payment'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _onClosePressed,
          ),
        ),
        body: Stack(
          alignment: Alignment.topCenter,
          children: [
            WebViewWidget(controller: _controller),
            if (_pageLoading || _verifying)
              const LinearProgressIndicator(minHeight: 2),
            if (_verifying)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black26,
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              widget.isAr
                                  ? 'جاري التحقق من الدفع...'
                                  : 'Verifying payment...',
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
      ),
    );
  }
}
