/// Firestore collection: `payment_logs` (audit trail for [company_payments]).
abstract final class PaymentLogFields {
  PaymentLogFields._();

  static const String collection = 'payment_logs';

  static const String paymentId = 'paymentId';
  static const String action = 'action';
  static const String oldStatus = 'oldStatus';
  static const String newStatus = 'newStatus';
  static const String performedBy = 'performedBy';
  static const String timestamp = 'timestamp';
  static const String notes = 'notes';
}

abstract final class PaymentLogAction {
  PaymentLogAction._();

  static const String created = 'created';
  static const String statusChanged = 'status_changed';
}
