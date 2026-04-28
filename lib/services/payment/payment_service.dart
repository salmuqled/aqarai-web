/// Abstraction for paid platform actions (auction fee, featured ad).
///
/// Server `markAuctionFeePaid` / `featurePropertyPaid` callables are
/// canonical: every payment is verified against MyFatoorah on the server
/// before Firestore is touched. This abstraction returns the gateway
/// `paymentId` alongside the success flag so the UI can hand it to the
/// callable; never derive the paid-state from the client side.
abstract class PaymentService {
  /// Auction listing fee checkout. Must return [AuctionFeePaymentUiResult]
  /// with a real MyFatoorah `paymentId` when the user completed the gateway
  /// flow. The server will reject mock/fake/simulate ids.
  Future<AuctionFeePaymentUiResult> payAuctionFee({
    required double amount,
    required String requestId,
  });

  /// Premium checkout for featuring an ad. MUST return a non-empty real
  /// MyFatoorah `paymentId` when the user completes payment.
  ///
  /// [durationDays] and [amountKwd] together identify the canonical
  /// `FEATURE_PLANS` entry on the server (3d/5, 7d/10, 14d/15, 30d/25 KWD);
  /// the server rejects pairs that don't match.
  Future<FeaturedAdPaymentUiResult> payFeaturedAd({
    required double amountKwd,
    required int durationDays,
    required String propertyId,
    required String description,
  });
}

class AuctionFeePaymentUiResult {
  const AuctionFeePaymentUiResult({
    required this.success,
    this.paymentId,
  });

  final bool success;

  /// Real MyFatoorah payment id (or equivalent gateway identifier). Server
  /// hard-rejects ids prefixed with `fake_`, `mock_`, or `simulate_`.
  final String? paymentId;
}

/// Why a featured-ad checkout did not return a verifiable [paymentId].
enum FeaturedAdPaymentFailure {
  /// Corresponds to [FeaturedAdPaymentUiResult.success] == true (ignore).
  none,

  /// User closed the WebView or left checkout without paying.
  userCancelled,

  /// Second tap while a session is already in progress.
  deduped,

  /// Cloud Function error, network error, or empty session payload.
  sessionCreateFailed,

  /// MyFatoorah error redirect or checkout could not complete.
  gatewayError,

  /// Mock/legacy paths without a finer classification.
  unknown,
}

class FeaturedAdPaymentUiResult {
  const FeaturedAdPaymentUiResult({
    required this.success,
    this.paymentId,
    this.failure = FeaturedAdPaymentFailure.unknown,
  });

  final bool success;

  /// [FeaturedAdPaymentFailure.none] when [success] is true.
  final FeaturedAdPaymentFailure failure;

  /// Real MyFatoorah payment id (or equivalent gateway identifier). Server
  /// hard-rejects ids prefixed with `fake_`, `mock_`, or `simulate_`.
  final String? paymentId;
}

/// Arabic snackbar for a failed feature checkout; null = show nothing.
String? messageForFeaturedAdFailureAr(FeaturedAdPaymentFailure f) {
  switch (f) {
    case FeaturedAdPaymentFailure.none:
      return null;
    case FeaturedAdPaymentFailure.userCancelled:
      return 'تم إلغاء الدفع';
    case FeaturedAdPaymentFailure.deduped:
      return null;
    case FeaturedAdPaymentFailure.sessionCreateFailed:
      return 'تعذر بدء جلسة الدفع. حاول مرة أخرى.';
    case FeaturedAdPaymentFailure.gatewayError:
      return 'تعذر إتمام الدفع عبر البوابة. حاول مرة أخرى.';
    case FeaturedAdPaymentFailure.unknown:
      return 'تعذر إتمام العملية';
  }
}
