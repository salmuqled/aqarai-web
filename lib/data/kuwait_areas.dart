// Central registry for Kuwait areas (code + Arabic + English).
// Initial subset; extend over time. Existing maps elsewhere stay unchanged until migrated.

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
