import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/constants/deal_constants.dart';

/// Optional manual maintenance for `deals` data quality. Nothing here runs automatically.
abstract final class DealDataIntegrityService {
  DealDataIntegrityService._();

  /// Sets [dealStatus] to [DealStatus.newLead] when the field is missing or blank.
  ///
  /// Paginates newest-first by [createdAt]. Call explicitly when you want a backfill;
  /// do not invoke from app startup. Stops after [maxDocumentsScanned] for safety.
  static Future<({int scanned, int updated})> fixMissingDealStatus({
    FirebaseFirestore? firestore,
    int pageSize = 300,
    int maxDocumentsScanned = 5000,
  }) async {
    final db = firestore ?? FirebaseFirestore.instance;
    var scanned = 0;
    var updated = 0;
    QueryDocumentSnapshot<Map<String, dynamic>>? cursor;

    while (scanned < maxDocumentsScanned) {
      Query<Map<String, dynamic>> q = db
          .collection('deals')
          .orderBy('createdAt', descending: true)
          .limit(pageSize);

      final last = cursor;
      if (last != null) {
        q = q.startAfterDocument(last);
      }

      final snap = await q.get();
      if (snap.docs.isEmpty) break;

      WriteBatch batch = db.batch();
      var pendingInBatch = 0;

      for (final d in snap.docs) {
        if (scanned >= maxDocumentsScanned) break;
        scanned++;

        final ds = d.data()['dealStatus']?.toString().trim() ?? '';
        if (ds.isEmpty) {
          batch.update(d.reference, {
            'dealStatus': DealStatus.newLead,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          pendingInBatch++;
          updated++;

          if (pendingInBatch >= 450) {
            await batch.commit();
            batch = db.batch();
            pendingInBatch = 0;
          }
        }
      }

      if (pendingInBatch > 0) {
        await batch.commit();
      }

      cursor = snap.docs.last;
      if (snap.docs.length < pageSize) break;
    }

    return (scanned: scanned, updated: updated);
  }
}
