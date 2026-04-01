import 'package:aqarai_app/services/payment/mock_payment_service.dart';
import 'package:aqarai_app/services/payment/payment_service.dart';

/// App-wide payment implementation. Change to [MyFatoorahPaymentService] when ready.
abstract final class PaymentServiceProvider {
  PaymentServiceProvider._();

  static PaymentService instance = MockPaymentService();
}
