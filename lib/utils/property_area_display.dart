import 'package:flutter/foundation.dart';

import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/utils/property_form_parsing.dart';

/// Shown when no usable area data exists. UI must not append `•` with this value.
const String kPropertyAreaUndetermined = 'غير محدد';

Map<String, String>? _areaCodeToAr;
Map<String, String>? _areaCodeToEn;

void _ensureAreaCodeMaps() {
  if (_areaCodeToAr != null) return;
  final toAr = <String, String>{};
  final toEn = <String, String>{};
  for (final e in areaArToEn.entries) {
    final code = propertyLocationCode(e.value.isNotEmpty ? e.value : e.key);
    if (code.isEmpty) continue;
    toAr[code] = e.key;
    if (e.value.isNotEmpty) toEn[code] = e.value;
  }
  _areaCodeToAr = toAr;
  _areaCodeToEn = toEn;
}

/// Strict validator for user-facing area strings from Firestore.
bool isValidArea(String? value) {
  if (value == null) return false;
  final t = value.trim();
  if (t.isEmpty) return false;
  switch (t.toLowerCase()) {
    case '-':
    case '—':
    case '–':
    case '−':
    case '…':
    case '...':
    case 'n/a':
    case 'null':
    case 'undefined':
      return false;
    default:
      return true;
  }
}

/// True when [value] is the undetermined sentinel (hide `•` in titles).
bool isPropertyAreaUndetermined(String value) =>
    value == kPropertyAreaUndetermined;

String? _stringField(Map<String, dynamic> data, String key) {
  final v = data[key];
  if (v == null) return null;
  return v.toString();
}

/// Firestore may use [areaCode] or legacy [area_id].
String _rawAreaCode(Map<String, dynamic> data) {
  final a = data['areaCode'];
  if (a != null && a.toString().trim().isNotEmpty) {
    return a.toString().trim();
  }
  final b = data['area_id'];
  if (b != null && b.toString().trim().isNotEmpty) {
    return b.toString().trim();
  }
  return '';
}

String? _arabicFromEnglishAreaLabel(String en) {
  final t = en.trim().toLowerCase();
  if (t.isEmpty) return null;
  for (final e in areaArToEn.entries) {
    if (e.value.trim().toLowerCase() == t) return e.key;
  }
  return null;
}

void _debugUnknownAreaCode(String codeRaw, String normalized) {
  if (!kDebugMode) return;
  debugPrint(
    'Unknown areaCode detected: raw="$codeRaw" normalized="$normalized"',
  );
}

/// Arabic area name from stable Firestore [areaCode] / [area_id], or empty if unknown.
String getAreaName(String? areaCode) {
  final raw = (areaCode ?? '').trim();
  if (raw.isEmpty) return '';
  _ensureAreaCodeMaps();
  final key = propertyLocationCode(raw);
  if (key.isEmpty) return '';
  return _areaCodeToAr![key] ?? '';
}

/// Display label for a Firestore [areaCode] slug (assistant suggestions, nearby copy).
/// Uses the same code→label maps as listing cards so UI matches search/analyze slugs.
String areaLabelForCode(String? areaCode, {required bool arabic}) {
  final raw = (areaCode ?? '').trim();
  if (raw.isEmpty) return '';
  _ensureAreaCodeMaps();
  final key = propertyLocationCode(raw);
  if (key.isEmpty) return raw;
  if (arabic) {
    return _areaCodeToAr![key] ?? raw;
  }
  return _areaCodeToEn![key] ?? _areaCodeToAr![key] ?? raw;
}

/// Priority (Arabic display):
/// 1. areaAr → 2. area → 3. areaEn (reverse EN→AR, else treat as code slug, else raw) →
/// 4. areaCode / area_id → map to Arabic.
String? _resolveArabicDisplay(Map<String, dynamic> data) {
  final arDirect = _stringField(data, 'areaAr');
  if (isValidArea(arDirect)) return arDirect!.trim();

  final areaLegacy = _stringField(data, 'area');
  if (isValidArea(areaLegacy)) return areaLegacy!.trim();

  final en = _stringField(data, 'areaEn');
  if (isValidArea(en)) {
    final t = en!.trim();
    final mapped = _arabicFromEnglishAreaLabel(t);
    if (mapped != null && isValidArea(mapped)) return mapped;
    final fromSlug = getAreaName(t);
    if (fromSlug.isNotEmpty) return fromSlug;
    return t;
  }

  final codeRaw = _rawAreaCode(data);
  if (codeRaw.isNotEmpty) {
    final normalized = propertyLocationCode(codeRaw);
    if (normalized.isEmpty) {
      _debugUnknownAreaCode(codeRaw, normalized);
    } else {
      final fromCode = getAreaName(codeRaw);
      if (fromCode.isNotEmpty) return fromCode;
      _debugUnknownAreaCode(codeRaw, normalized);
    }
  }

  return null;
}

/// Priority (English display):
/// 1. areaEn → 2. areaAr / area → English via map → 3. areaCode / area_id.
String? _resolveEnglishDisplay(Map<String, dynamic> data) {
  final en = _stringField(data, 'areaEn');
  if (isValidArea(en)) return en!.trim();

  for (final field in ['areaAr', 'area']) {
    final v = _stringField(data, field);
    if (!isValidArea(v)) continue;
    final t = v!.trim();
    final enLabel = areaArToEn[t];
    if (enLabel != null && isValidArea(enLabel)) return enLabel.trim();
    return t;
  }

  final codeRaw = _rawAreaCode(data);
  if (codeRaw.isNotEmpty) {
    _ensureAreaCodeMaps();
    final normalized = propertyLocationCode(codeRaw);
    if (normalized.isEmpty) {
      _debugUnknownAreaCode(codeRaw, normalized);
    } else {
      final label = _areaCodeToEn![normalized];
      if (label != null && isValidArea(label)) return label.trim();
      final ar = getAreaName(codeRaw);
      if (ar.isNotEmpty) return ar;
      _debugUnknownAreaCode(codeRaw, normalized);
    }
  }

  return null;
}

/// Fail-safe area label for property cards and lists.
///
/// Never returns an empty string or placeholder like `-`. On total failure returns
/// [kPropertyAreaUndetermined]; the UI should omit the `•` segment when
/// [isPropertyAreaUndetermined] is true.
String areaDisplayNameForProperty(Map<String, dynamic> data, String locale) {
  final primary = locale == 'ar'
      ? _resolveArabicDisplay(data)
      : _resolveEnglishDisplay(data);

  var resolved = (primary != null && primary.isNotEmpty)
      ? primary
      : kPropertyAreaUndetermined;

  if (!isValidArea(resolved)) {
    resolved = kPropertyAreaUndetermined;
  }

  if (kDebugMode) {
    debugPrint('AREA RESOLUTION:');
    debugPrint('areaAr: ${data['areaAr']}');
    debugPrint('areaEn: ${data['areaEn']}');
    debugPrint('areaCode: ${data['areaCode']}');
    debugPrint('area_id: ${data['area_id']}');
    debugPrint('area: ${data['area']}');
    debugPrint('final: $resolved');
  }

  return resolved;
}
