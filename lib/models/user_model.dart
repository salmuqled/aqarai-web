/// Firestore `users/{uid}` fields used for moderation and session checks.
abstract final class UserProfile {
  UserProfile._();

  static const String statusBanned = 'banned';

  /// True if [data] indicates an active ban (either flag or legacy status string).
  static bool isBannedFromData(Map<String, dynamic>? data) {
    if (data == null) return false;
    if (data['isBanned'] == true) return true;
    final s = data['status']?.toString();
    if (s == statusBanned) return true;
    return false;
  }
}
