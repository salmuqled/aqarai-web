import 'package:cloud_firestore/cloud_firestore.dart';

/// Returns the number of buyers interested in a given property configuration
/// by querying the [buyer_interests] collection.
class SellerRadarService {
  static const String _collection = 'buyer_interests';
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Returns the count of buyer_interests documents matching
  /// [areaCode], [type], and [serviceType].
  Future<int> getInterestedBuyersCount({
    required String areaCode,
    required String type,
    required String serviceType,
  }) async {
    final snapshot = await _firestore
        .collection(_collection)
        .where('areaCode', isEqualTo: areaCode)
        .where('type', isEqualTo: type)
        .where('serviceType', isEqualTo: serviceType)
        .get();
    return snapshot.docs.length;
  }
}
