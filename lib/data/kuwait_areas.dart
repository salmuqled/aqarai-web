// Central registry for Kuwait areas (code + Arabic + English).
// This is the single source of truth for generating stable `areaCode` values.
// Keep it extended and canonical to avoid search mismatches.

import 'package:aqarai_app/utils/property_form_parsing.dart';

class AreaModel {
  final String code;
  final String nameAr;
  final String nameEn;

  const AreaModel({
    required this.code,
    required this.nameAr,
    required this.nameEn,
  });
}

const List<AreaModel> kuwaitAreas = [
  AreaModel(code: 'salmiya', nameAr: 'السالمية', nameEn: 'Salmiya'),
  AreaModel(code: 'hawally', nameAr: 'حولي', nameEn: 'Hawally'),
  AreaModel(code: 'jabriya', nameAr: 'الجابرية', nameEn: 'Jabriya'),
  AreaModel(code: 'khaitan', nameAr: 'خيطان', nameEn: 'Khaitan'),
  AreaModel(code: 'farwaniya', nameAr: 'الفروانية', nameEn: 'Farwaniya'),
  AreaModel(code: 'mahboula', nameAr: 'المهبولة', nameEn: 'Mahboula'),
  AreaModel(code: 'fahaheel', nameAr: 'الفحيحيل', nameEn: 'Fahaheel'),
  // Khiran: official rows in governorates data (codes align with Firestore / functions/src/kuwait_areas.ts)
  AreaModel(
    code: 'sabah_al_ahmad_marine_khiran',
    nameAr: 'صباح الاحمد البحرية - الخيران',
    nameEn: 'Sabah Al-Ahmad Marine - Khiran',
  ),
  AreaModel(
    code: 'khiran_residential_inland',
    nameAr: 'الخيران السكنية - الجانب البري',
    nameEn: 'Khiran Residential - Inland',
  ),
  // Chalet areas (must match chalet search areas)
  AreaModel(code: 'khiran', nameAr: 'الخيران', nameEn: 'Khiran'),
  AreaModel(code: 'bneider', nameAr: 'بنيدر', nameEn: 'Bneider'),
  AreaModel(code: 'zour', nameAr: 'الزور', nameEn: 'Zour'),
  AreaModel(code: 'nuwaiseeb', nameAr: 'النويصيب', nameEn: 'Nuwaiseeb'),
  AreaModel(code: 'julaia', nameAr: 'الجليعة', nameEn: 'Julaia'),
  AreaModel(code: 'dhubaiya', nameAr: 'الضباعية', nameEn: 'Dhubaiya'),
];

AreaModel? getAreaByCode(String? code) {
  if (code == null) return null;
  try {
    return kuwaitAreas.firstWhere((a) => a.code == code);
  } catch (_) {
    return null;
  }
}

String getKuwaitAreaName(String? code, String locale) {
  final area = getAreaByCode(code);
  if (area == null) return '';

  return locale == 'ar' ? area.nameAr : area.nameEn;
}

String _collapseSpaces(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

String _normalizeLatin(String s) => _collapseSpaces(s).toLowerCase();

int _scoreNameMatch(String name, String query) {
  if (name.isEmpty || query.isEmpty) return 0;

  if (name == query) return 100;

  if (name.startsWith(query)) return 85;

  if (name.contains(query)) return 60;

  // Official governorate labels often wrap a short canonical name, e.g.
  // "صباح الاحمد البحرية - الخيران" contains "الخيران".
  if (name.length >= 2 && query.contains(name)) return 55;

  return 0;
}

/// Resolves [kuwaitAreas] entry from user text (Arabic or English label). Returns
/// canonical [AreaModel.code], or null if no match (caller should fall back to
/// existing slug encoding).
///
/// Picks the area with the highest score (AR and EN each scored; per-area score
/// is the max of the two). Ties keep the first winning entry in [kuwaitAreas]
/// order.
String? resolveAreaCodeFromText(String input) {
  final collapsed = _collapseSpaces(input);
  if (collapsed.isEmpty) return null;
  final latin = collapsed.toLowerCase();

  var bestScore = 0;
  String? bestCode;

  for (final a in kuwaitAreas) {
    final ar = _collapseSpaces(a.nameAr);
    final en = _normalizeLatin(a.nameEn);
    final scoreAr = _scoreNameMatch(ar, collapsed);
    final scoreEn = _scoreNameMatch(en, latin);
    final score = scoreAr > scoreEn ? scoreAr : scoreEn;
    if (score > bestScore) {
      bestScore = score;
      bestCode = a.code;
    }
  }

  return bestScore > 0 ? bestCode : null;
}

/// Kuwait's chalet coastal belt — canonical `areaCode` slugs that customers
/// treat as a single colloquial "chalet zone". Mirrors `CHALET_BELT_AREAS`
/// in `functions/src/kuwait_areas.ts`. Used by the conversational search
/// service to:
///
///   1. Expand a vague "ابي شاليه أي منطقة" request to the whole belt.
///   2. Validate that a multi-area request the LLM produced refers to belt
///      slugs only (no fabricated `khairan_benider_jaleea` style slugs).
///
/// Khiran's three sibling slugs are all included because customers say
/// "الخيران" to mean "anywhere in the Khiran corridor".
const List<String> chaletBeltAreas = [
  'khiran',
  'sabah_al_ahmad_marine_khiran',
  'khiran_residential_inland',
  'bneider',
  'julaia',
  'dhubaiya',
  'zour',
  'nuwaiseeb',
  'mina_abdullah',
];

bool isChaletBeltArea(String? areaCode) {
  if (areaCode == null) return false;
  final code = areaCode.trim().toLowerCase();
  return chaletBeltAreas.contains(code);
}

/// Unified `areaCode` generator:
/// 1) canonical code via [kuwaitAreas] matching (Arabic or English),
/// 2) fallback to [propertyLocationCode] slug when not found.
///
/// Use this everywhere to prevent mismatched `areaCode` values across flows.
String getUnifiedAreaCode(
  String input, {
  String? fallbackSlugSource,
}) {
  final collapsed = _collapseSpaces(input);
  final String? resolved = collapsed.isNotEmpty ? resolveAreaCodeFromText(collapsed) : null;
  if (resolved != null && resolved.isNotEmpty) return resolved;

  final fallbackInput = (fallbackSlugSource != null && fallbackSlugSource.trim().isNotEmpty)
      ? fallbackSlugSource
      : collapsed;
  final slug = propertyLocationCode(fallbackInput);
  return slug;
}
