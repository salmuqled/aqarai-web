import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';
import 'package:aqarai_app/models/auction/auction_log_entry.dart';

/// Append-only legal audit trail. Prefer calling from Cloud Functions for bids;
/// admins may log manual actions from the client per [Firestore rules].
abstract final class AuctionLogService {
  AuctionLogService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(AuctionFirestorePaths.logs);

  static Stream<List<AuctionLogEntry>> watchLogsForAuction(
    String auctionId, {
    int limit = 200,
  }) {
    return _col
        .where('auctionId', isEqualTo: auctionId)
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => AuctionLogEntry.fromFirestore(d.id, d.data()))
              .toList(),
        );
  }

  /// Client: allowed for admin in rules. System jobs should use Admin SDK.
  static Future<void> append({
    required String auctionId,
    String? lotId,
    required String action,
    required String performedBy,
    Map<String, dynamic>? details,
  }) async {
    await _col.add(
      AuctionLogEntry(
        id: '',
        auctionId: auctionId,
        lotId: lotId,
        action: action,
        performedBy: performedBy,
        details: details ?? const <String, dynamic>{},
        timestamp: DateTime.now(),
      ).toFirestore(),
    );
  }
}
