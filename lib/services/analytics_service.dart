import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/listing_enums.dart';

/// Aggregated business metrics at [analytics]/[globalDocId].
///
/// Firestore `FieldValue.increment` is atomic per field. All updates should run
/// in the same [WriteBatch] as the deal write when possible.
abstract final class AnalyticsService {
  static const String collection = 'analytics';
  static const String globalDocId = 'global';

  /// Maps stored `leadSource` values to metric key prefixes (`aiDeals` / `aiRevenue`, etc.).
  static String _metricsPrefix(String leadSource) {
    final s = leadSource.trim();
    switch (s) {
      case DealLeadSource.aiChat:
        return 'ai';
      case DealLeadSource.search:
        return 'search';
      case DealLeadSource.featured:
        return 'featured';
      case DealLeadSource.direct:
        return 'direct';
      case DealLeadSource.interestedButton:
        return 'direct';
      default:
        return 'unknown';
    }
  }

  /// Payload for `set(..., SetOptions(merge: true))` or [WriteBatch.set].
  static Map<String, dynamic> buildGlobalIncrementPayload({
    required String leadSource,
    required double volumeKwd,
    required double commissionKwd,
  }) {
    final prefix = _metricsPrefix(leadSource);
    return {
      'totalDeals': FieldValue.increment(1),
      'totalVolume': FieldValue.increment(volumeKwd),
      'totalCommission': FieldValue.increment(commissionKwd),
      '${prefix}Deals': FieldValue.increment(1),
      '${prefix}Revenue': FieldValue.increment(volumeKwd),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static DocumentReference<Map<String, dynamic>> globalRef(
    FirebaseFirestore db,
  ) => db.collection(collection).doc(globalDocId);

  /// Adjust volume/commission when a deal's final price or commission changes (delta only).
  static Map<String, dynamic> buildGlobalVolumeCommissionDelta({
    required String leadSource,
    required double deltaVolumeKwd,
    required double deltaCommissionKwd,
  }) {
    final prefix = _metricsPrefix(leadSource);
    return {
      if (deltaVolumeKwd != 0) ...{
        'totalVolume': FieldValue.increment(deltaVolumeKwd),
        '${prefix}Revenue': FieldValue.increment(deltaVolumeKwd),
      },
      if (deltaCommissionKwd != 0)
        'totalCommission': FieldValue.increment(deltaCommissionKwd),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}
