import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/models/support_ticket.dart';

/// User-facing create + profile snapshot for [support_tickets].
abstract final class SupportTicketService {
  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  static Future<({String userName, String userPhone})> resolveUserContact(
    User user,
  ) async {
    final snap = await _db.collection('users').doc(user.uid).get();
    final d = snap.data() ?? {};
    var name = (d['displayName'] ??
            d['fullName'] ??
            d['name'] ??
            user.displayName ??
            user.email ??
            '')
        .toString()
        .trim();
    if (name.isEmpty) name = '—';
    final phone = (d['phone'] ?? d['ownerPhone'] ?? d['userPhone'] ?? '')
        .toString()
        .trim();
    return (userName: name, userPhone: phone);
  }

  static Future<void> submitTicket({
    required String subject,
    required String message,
    required String category,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('not_signed_in');
    }
    if (!SupportTicketCategory.all.contains(category)) {
      throw ArgumentError('invalid category');
    }
    final contact = await resolveUserContact(user);
    await _db.collection('support_tickets').add({
      'userId': user.uid,
      'userName': contact.userName,
      'userPhone': contact.userPhone,
      'subject': subject.trim(),
      'message': message.trim(),
      'status': SupportTicketStatus.open,
      'category': category,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
