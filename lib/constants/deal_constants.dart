/// Canonical `deals.dealStatus` pipeline values stored in Firestore.
class DealStatus {
  DealStatus._();

  static const String newLead = 'new';
  static const String contacted = 'contacted';
  static const String qualified = 'qualified';
  static const String booked = 'booked';
  static const String signed = 'signed';
  static const String closed = 'closed';

  /// Terminal: lead declined / no longer pursuing (still valid CRM value).
  static const String notInterested = 'not_interested';
}

/// True when [status] matches a known pipeline stage (after trim).
bool isValidDealStatus(String status) {
  final s = status.trim();
  return s == DealStatus.newLead ||
      s == DealStatus.contacted ||
      s == DealStatus.qualified ||
      s == DealStatus.booked ||
      s == DealStatus.signed ||
      s == DealStatus.closed ||
      s == DealStatus.notInterested;
}
