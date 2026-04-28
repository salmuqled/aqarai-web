import 'dart:math';

import 'package:aqarai_app/services/payment/payment_service.dart';

/// Stand-in for MyFatoorah: delay + success. Replace with [MyFatoorahPaymentService] later.
class MockPaymentService implements PaymentService {
  MockPaymentService({
    this.failureRate = 0.0,
    Random? random,
  }) : _rng = random ?? Random();

  /// 0.0 = always success, 1.0 = always fail.
  final double failureRate;

  final Random _rng;

  String _uuidV4() {
    // Lightweight UUIDv4 generator (no extra dependencies).
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
    String h(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = bytes.map(h).join();
    return '${s.substring(0, 8)}-'
        '${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-'
        '${s.substring(16, 20)}-'
        '${s.substring(20)}';
  }

  @override
  Future<AuctionFeePaymentUiResult> payAuctionFee({
    required double amount,
    required String requestId,
  }) async {
    // The auction fee path now requires real MyFatoorah verification on the
    // server (Financial Hardening Phase 1). The mock has no way to produce a
    // valid gateway paymentId, so it deliberately fails so QA cannot pretend
    // a fee was paid in production builds.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return const AuctionFeePaymentUiResult(success: false);
  }

  @override
  Future<FeaturedAdPaymentUiResult> payFeaturedAd({
    required double amountKwd,
    required int durationDays,
    required String propertyId,
    required String description,
  }) async {
    // Simulate gateway UI latency (1–2s).
    await Future<void>.delayed(Duration(milliseconds: 1000 + _rng.nextInt(1000)));

    final fail = failureRate > 0 && _rng.nextDouble() < failureRate;
    if (fail) {
      return const FeaturedAdPaymentUiResult(
        success: false,
        failure: FeaturedAdPaymentFailure.unknown,
      );
    }

    return FeaturedAdPaymentUiResult(
      success: true,
      failure: FeaturedAdPaymentFailure.none,
      // Looks like a real gateway identifier. Prefix keeps it recognizable in logs.
      paymentId: 'fake_${_uuidV4()}',
    );
  }
}
