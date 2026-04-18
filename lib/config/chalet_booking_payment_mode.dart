/// App-side chalet checkout path after a `pending_payment` booking exists.
///
/// Use [getPaymentMode] everywhere the UI or services choose how to collect
/// payment — do not branch on booleans in widgets.
enum PaymentMode {
  fake,
  myfatoorah,
}

/// Legacy compile-time flag; [getPaymentMode] maps this to [PaymentMode].
///
/// Keep `true` for dev/QA fake pay; set `false` when the MyFatoorah WebView
/// flow is ready and [getPaymentMode] should return [PaymentMode.myfatoorah].
const bool kChaletUseFakePayment = true;

/// Single source of truth for which payment rail the confirmation flow uses.
///
/// To enable real gateway later: return [PaymentMode.myfatoorah] here (and/or
/// derive from remote config), without editing [BookingConfirmationPage].
PaymentMode getPaymentMode() {
  return kChaletUseFakePayment ? PaymentMode.fake : PaymentMode.myfatoorah;
}

/// Debug log for payment routing (no PII).
void logChaletPaymentMode(PaymentMode mode) {
  // ignore: avoid_print
  print('PAYMENT_MODE = $mode');
}
