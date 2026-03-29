import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/anonymous_user_id_store.dart';

/// Writes one `property_views` row per details open (non-admin). Failures are swallowed so UX is unaffected.
class PropertyViewTrackingService {
  PropertyViewTrackingService._();
  static final PropertyViewTrackingService instance = PropertyViewTrackingService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> recordView({
    required String propertyId,
    required String leadSource,
  }) async {
    if (propertyId.isEmpty) return;

    final ls = DealLeadSource.normalizeAttributionSource(leadSource);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final data = <String, dynamic>{
        'propertyId': propertyId,
        'leadSource': ls,
        'viewedAt': FieldValue.serverTimestamp(),
      };
      // Exactly one identity field: signed-in uid OR anonymous id (rules enforce this).
      if (uid != null && uid.isNotEmpty) {
        data['userId'] = uid;
      } else {
        data['anonymousId'] = await AnonymousUserIdStore.getOrCreate();
      }

      await _db.collection('property_views').add(data);
    } catch (_) {
      // Intentionally silent: tracking must not block or alarm the user.
    }
  }
}
