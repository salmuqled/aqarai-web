// Intentionally uses `dart:html` DOM APIs for SPA head/meta updates (`package:web`
// migration is tracked separately).

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:convert';
import 'dart:html' as html;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:aqarai_app/utils/listing_display.dart';
import 'package:aqarai_app/utils/property_listing_cover.dart';

const _ldScriptId = 'aqarai-property-json-ld';

/// Avoid rewriting the DOM when [FutureBuilder] rebuilds without material change.
String? _lastAppliedSignature;

void updatePropertyMeta(Map<String, dynamic> propertyDoc, String canonicalUrl) {
  final sig =
      '$canonicalUrl'
      '|${metaListingTitle(propertyDoc)}'
      '|${propertyDoc['price']}'
      '|${metaPrimaryImage(propertyDoc) ?? ''}';
  if (_lastAppliedSignature == sig) return;
  _lastAppliedSignature = sig;

  final displayTitle = metaListingTitle(propertyDoc).trim();
  final title = displayTitle.isEmpty ? 'AqarAi' : displayTitle;
  final headline = '$title | AqarAi';

  html.document.title = headline;

  final description = metaListingDescription(propertyDoc);
  _upsertMetaByName(name: 'description', content: description);

  _upsertOg(property: 'og:title', content: headline);
  _upsertOg(property: 'og:description', content: description);
  _upsertOg(property: 'og:type', content: 'website');

  final image = metaPrimaryImage(propertyDoc);
  if (image != null && image.isNotEmpty) {
    _upsertOg(property: 'og:image', content: image);
  }

  if (canonicalUrl.isNotEmpty) {
    _upsertOg(property: 'og:url', content: canonicalUrl);
  }

  _upsertCanonicalLink(canonicalUrl);

  _injectJsonLd(
    MetaListingPayload(
      propertyDoc: propertyDoc,
      canonicalUrl: canonicalUrl,
      imageUrl: image,
      headline: headline,
      description: description,
    ),
  );
}

/// Public for tests — primary display title aligned with UI [listingDisplayTitle].
String metaListingTitle(Map<String, dynamic> data) {
  final area = _pickAreaEnglish(data);
  final typeRaw = '${data['type'] ?? ''}'.trim();
  final typeLabel = _typeEnglish(typeRaw);
  return listingDisplayTitle(
    data,
    areaLabel: area.isEmpty ? 'Kuwait' : area,
    typeLabel: typeLabel,
  );
}

String _pickAreaEnglish(Map<String, dynamic> data) {
  final a =
      '${data['areaEn'] ?? data['area'] ?? data['areaAr'] ?? ''}'.trim();
  return a;
}

/// Short summary for `<meta name="description">`: service, price, size, type, location.
String metaListingDescription(Map<String, dynamic> d, {int maxLen = 168}) {
  final service = _serviceShortEn('${d['serviceType'] ?? ''}'.trim());
  final price = d['price'];
  final num? p = price is num ? price : num.tryParse('$price');
  final size = (d['size'] is num) ? (d['size'] as num).toDouble() : 0.0;
  final type = _typeEnglish('${d['type'] ?? ''}'.trim());
  final area = _pickAreaEnglish(d);

  final parts = <String>[];
  if (service.isNotEmpty) parts.add(service);
  if (p != null && p > 0) {
    parts.add('${p.toString()} KWD');
  }
  if (size > 0) {
    parts.add('${size.toStringAsFixed(size == size.roundToDouble() ? 0 : 1)} m²');
  }
  if (type.isNotEmpty) parts.add(type);
  if (area.isNotEmpty) parts.add(area);

  var s = parts.join(' · ');
  if (s.isEmpty) {
    s = 'Kuwait property listing on AqarAi.';
  }
  if (s.length > maxLen) {
    s = '${s.substring(0, maxLen - 1).trim()}…';
  }
  return s;
}

String _serviceShortEn(String serviceType) {
  switch (serviceType.toLowerCase()) {
    case 'sale':
      return 'For sale';
    case 'rent':
      return 'For rent';
    case 'exchange':
      return 'For exchange';
    default:
      return '';
  }
}

String _typeEnglish(String raw) {
  final v = raw.toLowerCase();
  switch (v) {
    case 'apartment':
      return 'Apartment';
    case 'house':
      return 'House';
    case 'building':
      return 'Building';
    case 'land':
      return 'Land';
    case 'industrialland':
      return 'Industrial land';
    case 'shop':
      return 'Shop';
    case 'office':
      return 'Office';
    case 'chalet':
      return 'Chalet';
    default:
      return raw.isEmpty ? 'Property' : raw;
  }
}

String? metaPrimaryImage(Map<String, dynamic> data) {
  return PropertyListingCover.urlFrom(data);
}

void _upsertMetaByName({required String name, required String content}) {
  final head = html.document.head;
  if (head == null) return;
  html.MetaElement el;
  final existing = head.querySelector('meta[name="$name"]');
  if (existing is html.MetaElement) {
    el = existing;
  } else {
    el = html.MetaElement()..setAttribute('name', name);
    head.append(el);
  }
  el.content = content;
}

void _upsertOg({required String property, required String content}) {
  final head = html.document.head;
  if (head == null) return;
  html.MetaElement el;
  final existing = head.querySelector('meta[property="$property"]');
  if (existing is html.MetaElement) {
    el = existing;
  } else {
    el = html.MetaElement()..setAttribute('property', property);
    head.append(el);
  }
  el.content = content;
}

void _upsertCanonicalLink(String href) {
  if (href.isEmpty) return;
  final head = html.document.head;
  if (head == null) return;
  html.LinkElement link;
  final existing = head.querySelector('link[rel="canonical"]');
  if (existing is html.LinkElement) {
    link = existing;
  } else {
    link = html.LinkElement()..rel = 'canonical';
    head.append(link);
  }
  link.href = href;
}

void _injectJsonLd(MetaListingPayload payload) {
  final head = html.document.head;
  if (head == null) return;
  html.document.getElementById(_ldScriptId)?.remove();

  final script =
      html.ScriptElement()
        ..id = _ldScriptId
        ..type = 'application/ld+json'
        ..text = jsonEncode(_buildRealEstateListingJsonLd(payload));

  head.append(script);
}

class MetaListingPayload {
  MetaListingPayload({
    required this.propertyDoc,
    required this.canonicalUrl,
    required this.imageUrl,
    required this.headline,
    required this.description,
  });

  final Map<String, dynamic> propertyDoc;
  final String canonicalUrl;
  final String? imageUrl;
  final String headline;
  final String description;
}

Map<String, dynamic> _buildRealEstateListingJsonLd(MetaListingPayload p) {
  final d = p.propertyDoc;

  final name = metaListingTitle(d);
  final rawPrice = d['price'];
  final num? offerPrice =
      rawPrice is num ? rawPrice : num.tryParse('$rawPrice');
  final size = (d['size'] is num) ? (d['size'] as num).toDouble() : null;
  final type = '${d['type'] ?? ''}'.trim();

  final governorate =
      '${d['governorateEn'] ?? d['governorate'] ?? ''}'.trim();

  final address = <String, dynamic>{
    '@type': 'PostalAddress',
    'addressCountry': 'KW',
    if (governorate.isNotEmpty) 'addressRegion': governorate,
  };
  final area = _pickAreaEnglish(d);
  if (area.isNotEmpty) {
    address['addressLocality'] = area;
  }

  final posted = d['createdAt'];
  String? isoPosted;
  if (posted is Timestamp) {
    isoPosted = posted.toDate().toUtc().toIso8601String();
  } else if (posted is DateTime) {
    isoPosted = posted.toUtc().toIso8601String();
  }

  final offers = <String, dynamic>{
    '@type': 'Offer',
    'priceCurrency': 'KWD',
    if (offerPrice != null && offerPrice > 0) 'price': offerPrice,
  };

  final listing = <String, dynamic>{
    '@context': 'https://schema.org',
    '@type': 'RealEstateListing',
    'name': name.isEmpty ? p.headline : name,
    'description': p.description,
    if (p.canonicalUrl.isNotEmpty) 'url': p.canonicalUrl,
    if (p.imageUrl != null && p.imageUrl!.isNotEmpty) 'image': p.imageUrl,
    if (isoPosted != null) 'datePosted': isoPosted,
    'address': address,
    'offers': offers,
  };

  if (size != null && size > 0) {
    listing['floorSize'] = {
      '@type': 'QuantitativeValue',
      'value': size,
      'unitCode': 'MTK',
    };
  }

  if (type.isNotEmpty) {
    listing['category'] = type;
  }

  return listing;
}
