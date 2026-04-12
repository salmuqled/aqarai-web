/// Cover URL for list cards: [coverUrl] → first [thumbnails] → first [images].
abstract final class PropertyListingCover {
  PropertyListingCover._();

  static String? urlFrom(Map<String, dynamic> data) {
    final cover = data['coverUrl']?.toString().trim();
    if (cover != null && cover.isNotEmpty) return cover;

    final thumbs = data['thumbnails'];
    if (thumbs is List && thumbs.isNotEmpty) {
      final s = thumbs.first?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }

    final images = data['images'];
    if (images is List && images.isNotEmpty) {
      final s = images.first?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    if (images is Map && images.isNotEmpty) {
      for (final v in images.values) {
        final s = v?.toString().trim();
        if (s != null && s.isNotEmpty) return s;
      }
    }
    return null;
  }
}
