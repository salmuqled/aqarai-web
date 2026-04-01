/// Firestore collection: `financial_ledger` (server-only writes).
abstract final class FinancialLedgerFields {
  FinancialLedgerFields._();

  static const String collection = 'financial_ledger';

  static const String id = 'id';
  static const String type = 'type';
  static const String amount = 'amount';
  static const String currency = 'currency';
  static const String source = 'source';
  static const String invoiceId = 'invoiceId';
  static const String paymentId = 'paymentId';
  static const String companyId = 'companyId';
  static const String createdAt = 'createdAt';
}

abstract final class FinancialLedgerType {
  FinancialLedgerType._();

  static const String income = 'income';
}

abstract final class FinancialLedgerSource {
  FinancialLedgerSource._();

  static const String invoice = 'invoice';
}
