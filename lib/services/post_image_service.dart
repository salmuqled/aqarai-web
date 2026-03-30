import 'package:cloud_functions/cloud_functions.dart';

/// Server-side Instagram-style square image (Admin callable → Storage URL only).
abstract final class PostImageService {
  PostImageService._();

  static FirebaseFunctions _funcs() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Returns public (or long-lived signed) image URL, or `null` on failure.
  static Future<String?> generateImage(String title, String subtitle) async {
    try {
      final callable = _funcs().httpsCallable('generatePostImage');
      final result = await callable.call<Map<String, dynamic>>({
        'title': title.trim(),
        'subtitle': subtitle.trim(),
      });
      final data = result.data;
      if (data['success'] == true && data['imageUrl'] is String) {
        return (data['imageUrl'] as String).trim();
      }
      return null;
    } on FirebaseFunctionsException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Admin carousel: 4 PNGs in Storage → public/signed URLs (order: slide 1…4).
  /// [demandLevel] must be `high`, `medium`, or `low` (e.g. [InstagramDemandLevel].name).
  static Future<List<String>> generateCarousel({
    required String title,
    required String area,
    required String propertyType,
    required String demandLevel,
    required int dealsCount,
  }) async {
    try {
      final callable = _funcs().httpsCallable('generateCarousel');
      final result = await callable.call<Map<String, dynamic>>({
        'title': title.trim(),
        'area': area.trim(),
        'propertyType': propertyType.trim(),
        'demandLevel': demandLevel.trim().toLowerCase(),
        'dealsCount': dealsCount,
      });
      final data = result.data;
      if (data['success'] != true || data['images'] is! List) {
        return const [];
      }
      final raw = data['images'] as List<dynamic>;
      final out = <String>[];
      for (final e in raw) {
        if (e is String && e.trim().isNotEmpty) {
          out.add(e.trim());
        }
      }
      return out;
    } on FirebaseFunctionsException {
      return const [];
    } catch (_) {
      return const [];
    }
  }
}
