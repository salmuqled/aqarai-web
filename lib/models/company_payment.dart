/// Firestore collection: `company_payments`
abstract final class CompanyPaymentFields {
  CompanyPaymentFields._();

  static const String collection = 'company_payments';

  static const String amount = 'amount';
  static const String type = 'type';
  static const String reason = 'reason';
  static const String source = 'source';
  /// Bank/check: required; must equal the Firestore document ID. Cash: omit field.
  static const String referenceNumber = 'referenceNumber';
  static const String relatedId = 'relatedId';
  static const String relatedType = 'relatedType';
  static const String notes = 'notes';
  static const String status = 'status';
  static const String createdAt = 'createdAt';
  static const String createdBy = 'createdBy';
  /// Last admin who created or updated this row (for audit / Cloud Functions).
  static const String updatedBy = 'updatedBy';
}

/// `status` field values. Only [confirmed] amounts count toward cash-in totals.
abstract final class CompanyPaymentStatus {
  CompanyPaymentStatus._();

  static const String pending = 'pending';
  static const String confirmed = 'confirmed';
  static const String rejected = 'rejected';

  static const List<String> values = [pending, confirmed, rejected];
}

/// `type` field values.
abstract final class CompanyPaymentType {
  CompanyPaymentType._();

  static const String auctionFee = 'auction_fee';
  static const String commission = 'commission';
  static const String other = 'other';

  static const List<String> values = [auctionFee, commission, other];
}

/// `reason` field values.
abstract final class CompanyPaymentReason {
  CompanyPaymentReason._();

  static const String sale = 'sale';
  static const String rent = 'rent';
  static const String auction = 'auction';
  static const String managementFee = 'management_fee';
  static const String other = 'other';

  static const List<String> values = [
    sale,
    rent,
    auction,
    managementFee,
    other,
  ];
}

/// `source` field values.
abstract final class CompanyPaymentSource {
  CompanyPaymentSource._();

  static const String bankTransfer = 'bank_transfer';
  static const String certifiedCheck = 'certified_check';
  static const String cash = 'cash';

  static const List<String> values = [
    bankTransfer,
    certifiedCheck,
    cash,
  ];
}

/// `relatedType` field values.
abstract final class CompanyPaymentRelatedType {
  CompanyPaymentRelatedType._();

  static const String auctionRequest = 'auction_request';
  static const String deal = 'deal';
  static const String manual = 'manual';

  static const List<String> values = [
    auctionRequest,
    deal,
    manual,
  ];
}
