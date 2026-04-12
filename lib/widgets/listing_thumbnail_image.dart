import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// List / card thumbnails: bounded decode + disk cache size to avoid full-res loads.
class ListingThumbnailImage extends StatelessWidget {
  const ListingThumbnailImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholderColor,
  });

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Color? placeholderColor;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    int? mw;
    int? mh;
    if (width != null) {
      mw = (width! * dpr).round().clamp(48, 900);
    }
    if (height != null) {
      mh = (height! * dpr).round().clamp(48, 900);
    }

    Widget child = CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: mw,
      memCacheHeight: mh,
      maxWidthDiskCache: mw,
      maxHeightDiskCache: mh,
      fadeInDuration: const Duration(milliseconds: 280),
      fadeOutDuration: const Duration(milliseconds: 120),
      placeholder: (_, _) => ColoredBox(
        color: placeholderColor ?? Colors.grey.shade200,
      ),
      errorWidget: (_, _, _) => ColoredBox(
        color: Colors.grey.shade300,
      ),
    );

    if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }
}
