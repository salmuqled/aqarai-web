import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class InvoiceViewerPage extends StatefulWidget {
  const InvoiceViewerPage({
    super.key,
    required this.invoiceUrl,
  });

  final String invoiceUrl;

  @override
  State<InvoiceViewerPage> createState() => _InvoiceViewerPageState();
}

class _InvoiceViewerPageState extends State<InvoiceViewerPage> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _hasError = false;

  bool get _isAr => Localizations.localeOf(context).languageCode == 'ar';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _progress = p.clamp(0, 100));
          },
          onWebResourceError: (_) {
            if (!mounted) return;
            setState(() => _hasError = true);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.invoiceUrl));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isAr ? 'الفاتورة' : 'Invoice'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          if (_hasError)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _isAr
                      ? 'تعذر فتح الفاتورة. حاول مرة أخرى.'
                      : 'Could not open invoice. Please try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.error,
                    fontWeight: FontWeight.w700,
                    height: 1.4,
                  ),
                ),
              ),
            )
          else
            WebViewWidget(controller: _controller),
          if (!_hasError && _progress < 100)
            LinearProgressIndicator(
              value: _progress / 100.0,
              minHeight: 2,
              color: cs.primary,
              backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.6),
            ),
        ],
      ),
    );
  }
}

