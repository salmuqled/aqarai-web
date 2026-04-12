/// YouTube / Vimeo URLs → embed URL for in-app WebView.
abstract final class VideoEmbedUrl {
  VideoEmbedUrl._();

  /// Standard YouTube id length (with regex fallback on raw strings).
  static final RegExp _ytIdExtract = RegExp(
    r'(?:youtube\.com\/(?:watch\?(?:[^&\s#]*&)?v=|embed\/|shorts\/|live\/)|youtu\.be\/)([a-zA-Z0-9_-]{11})\b',
    caseSensitive: false,
  );

  /// Empty is allowed (no video). Non-empty must be a supported link.
  static bool isEmptyOrValid(String? raw) {
    final t = raw?.trim() ?? '';
    if (t.isEmpty) return true;
    return parseToEmbedUrl(t) != null;
  }

  /// `www.youtube.com/...` and similar without scheme.
  static String _normalizeUrlInput(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    final lower = s.toLowerCase();
    if (!lower.contains('://') &&
        (lower.startsWith('www.') ||
            lower.startsWith('m.') ||
            lower.startsWith('youtube.') ||
            lower.startsWith('youtu.be'))) {
      s = 'https://$s';
    }
    return s;
  }

  /// YouTube video id if [input] is a recognized YouTube URL, else `null`.
  static String? parseYoutubeVideoId(String input) {
    final normalized = _normalizeUrlInput(input);
    if (normalized.isEmpty) return null;

    final fromRegex = _ytIdExtract.firstMatch(normalized)?.group(1);
    if (fromRegex != null && fromRegex.isNotEmpty) return fromRegex;

    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be' ||
        host.endsWith('.youtu.be') ||
        host.contains('youtube.com')) {
      return _youtubeIdFromUri(uri);
    }
    return null;
  }

  /// In-app WebView URL (no autoplay; user taps play in the YouTube chrome).
  static String? youtubeEmbedUrlForWebView(String input) {
    final id = parseYoutubeVideoId(input);
    if (id == null || id.isEmpty) return null;
    return 'https://www.youtube.com/embed/$id'
        '?playsinline=1'
        '&rel=0'
        '&modestbranding=1'
        '&autoplay=0';
  }

  /// In-app WebView watch page (more reliable than embed on iOS app webviews).
  static String? youtubeWatchUrlForWebView(String input) {
    final id = parseYoutubeVideoId(input);
    if (id == null || id.isEmpty) return null;
    return 'https://m.youtube.com/watch?v=$id&playsinline=1';
  }

  /// Official static thumbnail (may 404 for private/invalid ids).
  static String? youtubeThumbnailUrl(String input) {
    final id = parseYoutubeVideoId(input);
    if (id == null || id.isEmpty) return null;
    return 'https://img.youtube.com/vi/$id/0.jpg';
  }

  /// Returns embed URL, or `null` if not YouTube/Vimeo.
  static String? parseToEmbedUrl(String input) {
    final normalized = _normalizeUrlInput(input);
    if (normalized.isEmpty) return null;

    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme) return null;

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;

    final host = uri.host.toLowerCase();

    // Already a YouTube embed
    if (host.contains('youtube.com') &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'embed') {
      return normalized;
    }

    // youtu.be / youtube watch / shorts / m.youtube
    if (host == 'youtu.be' ||
        host.endsWith('.youtu.be') ||
        host.contains('youtube.com')) {
      final id = _youtubeIdFromUri(uri);
      if (id != null && id.isNotEmpty) {
        return 'https://www.youtube.com/embed/$id';
      }
    }

    // Vimeo
    if (host.contains('vimeo.com')) {
      if (uri.pathSegments.length >= 2 &&
          uri.pathSegments.first == 'video') {
        final id = uri.pathSegments[1];
        if (RegExp(r'^\d+$').hasMatch(id)) {
          return 'https://player.vimeo.com/video/$id';
        }
      }
      if (uri.pathSegments.isNotEmpty) {
        final last = uri.pathSegments.last;
        if (RegExp(r'^\d+$').hasMatch(last)) {
          return 'https://player.vimeo.com/video/$last';
        }
      }
    }

    return null;
  }

  static String? _youtubeIdFromUri(Uri uri) {
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return v;

    final segs = uri.pathSegments;
    if (segs.isEmpty) return null;

    if (uri.host == 'youtu.be' || uri.host.endsWith('.youtu.be')) {
      return segs.first;
    }

    if (segs.length >= 2) {
      if (segs[0] == 'shorts' || segs[0] == 'embed' || segs[0] == 'live') {
        return segs[1];
      }
    }

    return null;
  }
}
