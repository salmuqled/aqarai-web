import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/config/auction_analytics.dart';

/// Client-side auction analytics (currently `auction_viewed` only; other events are server-written).
abstract final class AuctionAnalyticsService {
  AuctionAnalyticsService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// One logical view per screen open; safe to call from `initState` + post-frame.
  static Future<void> logAuctionViewed({required String lotId}) async {
    final id = lotId.trim();
    if (id.isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await _db.collection(AuctionAnalytics.collection).add({
        'eventType': AuctionAnalytics.auctionViewed,
        'userId': user.uid,
        'lotId': id,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Non-blocking: never break UX on analytics.
    }
  }
}
