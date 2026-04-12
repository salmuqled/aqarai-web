import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'package:aqarai_app/utils/video_embed_url.dart';

/// In-app playback via WebView (YouTube + Vimeo).
///
/// Notes:
/// - Many YouTube videos refuse embed playback in app webviews (e.g. error 153).
///   Loading the normal watch page is more reliable on iOS.
class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.videoUrl});

  /// Original or share URL.
  final String videoUrl;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  WebViewController? _controller;
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final ytWatch = VideoEmbedUrl.youtubeWatchUrlForWebView(widget.videoUrl);
    final otherEmbed =
        ytWatch != null ? null : VideoEmbedUrl.parseToEmbedUrl(widget.videoUrl);
    final url = ytWatch ?? otherEmbed;

    if (url == null || url.isEmpty) {
      _error = 'Unsupported video link';
      _loading = false;
      return;
    }

    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (err) {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = err.description;
              });
            }
          },
        ),
      )
      ..enableZoom(false)
      ..loadRequest(Uri.parse(url));

    final platform = _controller!.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(isAr ? 'فيديو العقار' : 'Property video'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            )
          else if (_controller != null)
            WebViewWidget(controller: _controller!),
          if (_loading && _error == null)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
        ],
      ),
    );
  }
}
