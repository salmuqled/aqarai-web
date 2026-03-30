/// Replace with your deployed web / universal-link base (Instagram bio links).
///
/// Example: `https://yourapp.com/property` → `?id=...&cid=A`
abstract final class CaptionTrackingConfig {
  CaptionTrackingConfig._();

  /// Base path for “open property” links embedded in captions (no trailing `?`).
  static const String propertyLinkBase = 'https://yourapp.com/property';

  /// Builds a trackable deep link; [propertyId] may be empty (then only `cid` is sent).
  static String propertyOpenUrl(String propertyId, String captionVariantId) {
    final cid = Uri.encodeQueryComponent(captionVariantId.trim());
    if (propertyId.trim().isEmpty) {
      return '$propertyLinkBase?cid=$cid';
    }
    final id = Uri.encodeQueryComponent(propertyId.trim());
    return '$propertyLinkBase?id=$id&cid=$cid';
  }
}
