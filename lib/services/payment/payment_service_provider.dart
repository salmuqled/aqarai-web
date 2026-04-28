import 'package:aqarai_app/services/payment/myfatoorah_payment_service.dart';
import 'package:aqarai_app/services/payment/payment_service.dart';

/// App-wide payment implementation.
///
/// Uses the real [MyFatoorahPaymentService] which:
///   1. Calls a server callable to mint a hosted-payment-page session.
///   2. Opens the URL in an in-app WebView.
///   3. Returns the gateway `paymentId` for the caller to hand to the
///      authoritative finalize callable (`markAuctionFeePaid` /
///      `featurePropertyPaid`).
///
/// The MyFatoorah environment (sandbox vs. live) is controlled exclusively
/// by the backend `MYFATOORAH_API_BASE_URL` env var + the `MYFATOORAH_API_KEY`
/// Secret Manager secret. Flutter has zero environment knobs.
abstract final class PaymentServiceProvider {
  PaymentServiceProvider._();

  static PaymentService instance = MyFatoorahPaymentService();
}
