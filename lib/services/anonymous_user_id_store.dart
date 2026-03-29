import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Stable per-install id for logged-out users (property view analytics).
class AnonymousUserIdStore {
  AnonymousUserIdStore._();

  static const _key = 'aqarai_anonymous_viewer_id_v1';

  static Future<String> getOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_key);
    if (existing != null && existing.length >= 16) return existing;

    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString(_key, id);
    return id;
  }
}
