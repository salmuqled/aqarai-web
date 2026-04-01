import 'package:aqarai_app/services/payment/payment_service.dart';

/// Stand-in for MyFatoorah: delay + success. Replace with [MyFatoorahPaymentService] later.
class MockPaymentService implements PaymentService {
  @override
  Future<bool> payAuctionFee({
    required double amount,
    required String requestId,
  }) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    return true;
  }
}
