/// App-side chalet checkout path after a `pending_payment` booking exists.
///
/// Use [getPaymentMode] everywhere the UI or services choose how to collect
/// payment — do not branch on booleans in widgets.
enum PaymentMode {
  fake,
  myfatoorah,
}

/// Production hard-pinned to MyFatoorah.
///
/// The fake-pay rail (`kChaletUseFakePayment = true`) was used during DEV/QA
/// only. As of the Financial Hardening sprint (Phase 1) the matching server
/// callables (`fakePayChaletBooking`, `simulateChaletBookingPayment`) are
/// permanently disabled and always reject. DO NOT flip this back to `true`
/// without first restoring those server callables.
const bool kChaletUseFakePayment = false;

/// Single source of truth for which payment rail the confirmation flow uses.
PaymentMode getPaymentMode() {
  return kChaletUseFakePayment ? PaymentMode.fake : PaymentMode.myfatoorah;
}

/// Debug log for payment routing (no PII).
void logChaletPaymentMode(PaymentMode mode) {
  // ignore: avoid_print
  print('PAYMENT_MODE = $mode');
}
