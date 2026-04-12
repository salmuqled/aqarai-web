/// Abstraction for auction fee checkout. Swap implementation for MyFatoorah (or other)
/// without changing UI or Firestore field names — server [markAuctionFeePaid] remains canonical.
abstract class PaymentService {
  /// Simulates or performs client-side payment UI / redirect. Must return `true` only
  /// when the user completed the gateway flow; actual Firestore `paid` state is set by Cloud Functions.
  Future<bool> payAuctionFee({
    required double amount,
    required String requestId,
  });

  /// Premium checkout for featuring an ad. Gateway integration (MyFatoorah) should
  /// return a non-empty reference when the user completes payment.
  Future<FeaturedAdPaymentUiResult> payFeaturedAd({
    required double amountKwd,
    required String propertyId,
    required String description,
  });
}

class FeaturedAdPaymentUiResult {
  const FeaturedAdPaymentUiResult({
    required this.success,
    this.paymentId,
  });

  final bool success;
  /// MyFatoorah payment id (or equivalent gateway identifier).
  final String? paymentId;
}
