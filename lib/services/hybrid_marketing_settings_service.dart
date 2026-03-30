import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/hybrid_marketing_settings.dart';
import 'package:aqarai_app/services/admin_settings_service.dart';

export 'package:aqarai_app/models/hybrid_marketing_settings.dart';

/// Hybrid automation settings backed by [AdminSettingsService] (Firestore).
abstract final class HybridMarketingSettingsService {
  HybridMarketingSettingsService._();

  static Stream<HybridMarketingSettings> watch() =>
      AdminSettingsService.watchSettings();

  static Future<HybridMarketingSettings> load() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(AdminSettingsService.collection)
          .doc(AdminSettingsService.globalDocId)
          .get();
      return HybridMarketingSettings.fromFirestoreMap(doc.data());
    } catch (_) {
      return HybridMarketingSettings.defaults;
    }
  }

  static Future<void> save(HybridMarketingSettings s) =>
      AdminSettingsService.saveSettings(s);
}
