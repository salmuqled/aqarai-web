/// Values stored in Firestore `support_tickets.status`.
abstract final class SupportTicketStatus {
  static const String open = 'open';
  static const String inProgress = 'in_progress';
  static const String resolved = 'resolved';

  static bool isValid(String? s) {
    return s == open || s == inProgress || s == resolved;
  }
}

/// Values stored in Firestore `support_tickets.category`.
abstract final class SupportTicketCategory {
  static const String general = 'general';
  static const String bug = 'bug';
  static const String propertyInquiry = 'property_inquiry';
  static const String payment = 'payment';

  static const List<String> all = [
    general,
    bug,
    propertyInquiry,
    payment,
  ];
}
