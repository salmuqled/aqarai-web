import 'web_meta_helper_stub.dart'
    if (dart.library.html) 'web_meta_helper_web.dart' as impl;

/// Updates `<title>`, description, Open Graph tags, canonical link, and JSON-LD
/// for the current property (web only; no-op on mobile/desktop VM).
void updatePropertyMeta(Map<String, dynamic> propertyDoc, String canonicalUrl) {
  impl.updatePropertyMeta(propertyDoc, canonicalUrl);
}
