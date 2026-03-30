import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/models/user_model.dart';

/// Client-side ban checks (Firestore). Auth disable is enforced server-side.
abstract final class UserBanService {
  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  static Future<bool> isCurrentUserBanned() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return false;
    final snap = await _db.collection('users').doc(u.uid).get();
    return UserProfile.isBannedFromData(snap.data());
  }

  static Stream<bool> watchCurrentUserBanned() {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      return Stream<bool>.value(false);
    }
    return _db.collection('users').doc(u.uid).snapshots().map(
          (s) => UserProfile.isBannedFromData(s.data()),
        );
  }
}
