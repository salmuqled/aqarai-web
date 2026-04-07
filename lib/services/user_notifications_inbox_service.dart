import 'package:cloud_firestore/cloud_firestore.dart';

/// In-app inbox for `notifications` (same collection as F CM logging).
abstract final class UserNotificationsInboxService {
  UserNotificationsInboxService._();

  static const int inboxLimit = 50;

  static Query<Map<String, dynamic>> inboxQuery(String uid) {
    return FirebaseFirestore.instance
        .collection('notifications')
        .where('userId', isEqualTo: uid)
        .where('isHidden', isNotEqualTo: true)
        .orderBy('isHidden')
        .orderBy('createdAt', descending: true)
        .limit(inboxLimit);
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> inboxStream(String uid) {
    return inboxQuery(uid).snapshots();
  }

  /// Unread count among the [inboxLimit] most recent rows (matches list scope).
  static Stream<int> unreadCountRecentStream(String uid) {
    return inboxStream(uid).map(
      (s) => s.docs.where((d) => d.data()['isRead'] != true).length,
    );
  }

  /// FCM-style map for [NotificationService.navigateCommerceDeepLink].
  static Map<String, dynamic> deepLinkDataFromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final m = doc.data();
    final out = <String, dynamic>{'notificationId': doc.id};
    final nested = m['data'];
    if (nested is Map) {
      for (final e in nested.entries) {
        out[e.key.toString()] = e.value?.toString() ?? '';
      }
    }
    var nType = m['notificationType']?.toString() ?? '';
    if (nType == 'cancel') {
      nType = 'booking';
      final ba = out['bookingAction']?.toString().trim() ?? '';
      if (ba.isEmpty) {
        out['bookingAction'] = 'cancelled';
      }
    }
    out['notificationType'] = nType;
    return out;
  }

  /// UI + legacy docs without `priority`: booking/payout = high; refund/cancel = normal.
  static bool isHighPriority(Map<String, dynamic> m) {
    final p = m['priority']?.toString().toLowerCase().trim();
    if (p == 'high') return true;
    if (p == 'normal') return false;
    final t = (m['notificationType']?.toString() ?? '').toLowerCase().trim();
    return t == 'booking' || t == 'payout';
  }

  static Future<void> markAllReadFromSnapshot(
    QuerySnapshot<Map<String, dynamic>> snap,
  ) async {
    final batch = FirebaseFirestore.instance.batch();
    var n = 0;
    for (final d in snap.docs) {
      if (d.data()['isRead'] == true) continue;
      batch.update(d.reference, {'isRead': true});
      n++;
    }
    if (n > 0) {
      await batch.commit();
    }
  }

  /// Hides every doc in the current inbox snapshot (same scope as the list).
  static Future<void> hideAllVisibleFromSnapshot(
    QuerySnapshot<Map<String, dynamic>> snap,
  ) async {
    final batch = FirebaseFirestore.instance.batch();
    var n = 0;
    for (final d in snap.docs) {
      if (d.data()['isHidden'] == true) continue;
      batch.update(d.reference, {'isHidden': true});
      n++;
    }
    if (n > 0) {
      await batch.commit();
    }
  }
}
