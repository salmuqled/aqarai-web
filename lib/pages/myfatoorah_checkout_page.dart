import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Result of an in-app MyFatoorah hosted checkout. Verification happens on
/// the server (via `markAuctionFeePaid` / `featurePropertyPaid` /
/// `myFatoorahWebhook`); this page only captures the deep-link callback.
class MyFatoorahCheckoutResult {
  const MyFatoorahCheckoutResult({
    required this.success,
    required this.paymentId,
    this.userAborted = false,
  });

  final bool success;
  final String paymentId;

  /// When [success] is false, true if the user closed checkout without paying.
  final bool userAborted;
}

/// Generic MyFatoorah hosted-payment-page WebView. Intercepts redirects to
/// `aqarai://payment/<successPathSegment>/...` (returns success) and any
/// `aqarai://payment/.../error...` (returns failure). The caller is expected
/// to start a server-issued [paymentUrl] and pass the [paymentId] returned
/// from the matching server callable.
///
/// Usage:
/// ```
/// final res = await Navigator.of(context).push<MyFatoorahCheckoutResult>(
///   MaterialPageRoute(
///     builder: (_) => MyFatoorahCheckoutPage(
///       paymentUrl: paymentUrl,
///       paymentId: paymentId,
///       successHostPath: 'payment/auction/success',
///       errorHostPath: 'payment/auction/error',
///     ),
///   ),
/// );
/// ```
class MyFatoorahCheckoutPage extends StatefulWidget {
  const MyFatoorahCheckoutPage({
    super.key,
    required this.paymentUrl,
    required this.paymentId,
    required this.successHostPath,
    required this.errorHostPath,
    required this.isAr,
    this.title,
  });

  final String paymentUrl;

  /// Gateway PaymentId returned by the server callable. Used as the seed when
  /// the deep-link query string omits `paymentId` (some MF flows do).
  final String paymentId;

  /// e.g. `payment/auction/success` matches `aqarai://payment/auction/success?...`.
  final String successHostPath;

  /// e.g. `payment/auction/error`.
  final String errorHostPath;

  final bool isAr;
  final String? title;

  @override
  State<MyFatoorahCheckoutPage> createState() => _MyFatoorahCheckoutPageState();
}

class _MyFatoorahCheckoutPageState extends State<MyFatoorahCheckoutPage> {
  late final WebViewController _controller;
  var _pageLoading = true;
  var _handled = false;

  @override
  void initState() {
    super.initState();
    debugPrint(
      'MF_CHECKOUT_OPENED success=${widget.successHostPath} '
      'paymentId=${widget.paymentId}',
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
    final successKey = 'aqarai://${widget.successHostPath}'.toLowerCase();
    final errorKey = 'aqarai://${widget.errorHostPath}'.toLowerCase();

    if (lower.startsWith(successKey)) {
      _handled = true;
      final uri = Uri.tryParse(url);
      final pidFromUrl = uri?.queryParameters['paymentId']?.trim();
      final paymentId = (pidFromUrl != null && pidFromUrl.isNotEmpty)
          ? pidFromUrl
          : widget.paymentId;
      debugPrint('MF_CHECKOUT_SUCCESS paymentId=$paymentId');
      if (mounted) {
        Navigator.of(context).pop(
          MyFatoorahCheckoutResult(success: true, paymentId: paymentId),
        );
      }
      return;
    }

    if (lower.startsWith(errorKey)) {
      _handled = true;
      debugPrint('MF_CHECKOUT_FAILED reason=gateway_error_redirect url=$url');
      if (mounted) {
        Navigator.of(context).pop(
          MyFatoorahCheckoutResult(
            success: false,
            paymentId: widget.paymentId,
            userAborted: false,
          ),
        );
      }
    }
  }

  Future<void> _onClosePressed() async {
    if (_handled) return;
    final cancel = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isAr ? 'إلغاء الدفع؟' : 'Cancel payment?'),
        content: Text(
          widget.isAr
              ? 'إذا غادرت الآن لن يتم تأكيد العملية.'
              : 'If you leave now the operation will not be confirmed.',
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
    if (cancel != true || !mounted) return;
    _handled = true;
    debugPrint('MF_CHECKOUT_CANCELLED reason=user_dismissed');
    Navigator.of(context).pop(
      MyFatoorahCheckoutResult(
        success: false,
        paymentId: widget.paymentId,
        userAborted: true,
      ),
    );
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
          title: Text(widget.title ?? (widget.isAr ? 'الدفع' : 'Payment')),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _onClosePressed,
          ),
        ),
        body: Stack(
          alignment: Alignment.topCenter,
          children: [
            WebViewWidget(controller: _controller),
            if (_pageLoading) const LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    );
  }
}
