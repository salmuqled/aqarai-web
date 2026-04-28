import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/navigation_keys.dart';
import 'package:aqarai_app/pages/myfatoorah_checkout_page.dart';
import 'package:aqarai_app/services/payment/payment_service.dart';

/// Real MyFatoorah implementation of [PaymentService] for the auction listing
/// fee and the featured-ad upgrade.
///
/// Architecture (mirrors the booking flow):
///   1. Flutter calls `createAuctionFeeMyFatoorahPayment` /
///      `createFeaturePropertyMyFatoorahPayment`. The server uses its
///      `MYFATOORAH_API_KEY` secret to mint a hosted-payment-page URL.
///   2. We open the URL inside [MyFatoorahCheckoutPage] (WebView) and watch
///      for the `aqarai://payment/.../success|error` deep link.
///   3. On success, we hand the gateway `paymentId` back to the caller. The
///      caller then invokes the canonical finalize callable
///      (`markAuctionFeePaid` / `featurePropertyPaid`) which performs the
///      authoritative server-side `GetPaymentStatus` verification.
///
/// The API token is NEVER read on the client. The whole class only ever talks
/// to our own Cloud Functions.
///
/// To go live, change `MYFATOORAH_API_BASE_URL` (functions env) and rotate
/// the `MYFATOORAH_API_KEY` Secret Manager secret. No client-side change.
class MyFatoorahPaymentService implements PaymentService {
  MyFatoorahPaymentService({
    FirebaseFunctions? functions,
    GlobalKey<NavigatorState>? navigatorKey,
  })  : _functions = functions ?? FirebaseFunctions.instance,
        _navigatorKey = navigatorKey ?? rootNavigatorKey;

  final FirebaseFunctions _functions;
  final GlobalKey<NavigatorState> _navigatorKey;

  /// Prevents overlapping HTTPS + WebView work when the user double-taps pay.
  static bool _auctionSessionInFlight = false;
  static bool _featureSessionInFlight = false;

  bool _isArabic() {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return true; // default to AR for our market
    try {
      return Localizations.localeOf(ctx).languageCode == 'ar';
    } catch (_) {
      return true;
    }
  }

  Future<MyFatoorahCheckoutResult?> _runCheckout({
    required String paymentUrl,
    required String paymentId,
    required String successHostPath,
    required String errorHostPath,
  }) async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      debugPrint('MF_CHECKOUT_NO_NAVIGATOR');
      return null;
    }
    final isAr = _isArabic();
    return navigator.push<MyFatoorahCheckoutResult>(
      MaterialPageRoute<MyFatoorahCheckoutResult>(
        builder: (_) => MyFatoorahCheckoutPage(
          paymentUrl: paymentUrl,
          paymentId: paymentId,
          successHostPath: successHostPath,
          errorHostPath: errorHostPath,
          isAr: isAr,
        ),
      ),
    );
  }

  @override
  Future<AuctionFeePaymentUiResult> payAuctionFee({
    required double amount,
    required String requestId,
  }) async {
    if (_auctionSessionInFlight) {
      debugPrint('MF_AUCTION_SESSION_DEDUPED');
      return const AuctionFeePaymentUiResult(success: false);
    }
    _auctionSessionInFlight = true;
    try {
      final lang = _isArabic() ? 'ar' : 'en';
      final HttpsCallableResult<Object?> resp;
      try {
        resp = await _functions
            .httpsCallable('createAuctionFeeMyFatoorahPayment')
            .call<Object?>(<String, dynamic>{
          'requestId': requestId,
          'lang': lang,
        });
      } on FirebaseFunctionsException catch (e) {
        debugPrint('MF_CREATE_AUCTION_SESSION_FAILED ${e.code} ${e.message}');
        return const AuctionFeePaymentUiResult(success: false);
      } catch (e) {
        debugPrint('MF_CREATE_AUCTION_SESSION_FAILED $e');
        return const AuctionFeePaymentUiResult(success: false);
      }

      final data = (resp.data as Map?) ?? const <Object?, Object?>{};
      final paymentUrl = (data['paymentUrl'] as String?)?.trim() ?? '';
      final paymentId = (data['paymentId'] as String?)?.trim() ?? '';
      if (paymentUrl.isEmpty || paymentId.isEmpty) {
        return const AuctionFeePaymentUiResult(success: false);
      }

      final result = await _runCheckout(
        paymentUrl: paymentUrl,
        paymentId: paymentId,
        successHostPath: 'payment/auction/success',
        errorHostPath: 'payment/auction/error',
      );
      if (result == null || !result.success) {
        return const AuctionFeePaymentUiResult(success: false);
      }
      return AuctionFeePaymentUiResult(
        success: true,
        paymentId: result.paymentId,
      );
    } finally {
      _auctionSessionInFlight = false;
    }
  }

  @override
  Future<FeaturedAdPaymentUiResult> payFeaturedAd({
    required double amountKwd,
    required int durationDays,
    required String propertyId,
    required String description,
  }) async {
    if (_featureSessionInFlight) {
      debugPrint('MF_FEATURE_SESSION_DEDUPED');
      return const FeaturedAdPaymentUiResult(
        success: false,
        failure: FeaturedAdPaymentFailure.deduped,
      );
    }
    _featureSessionInFlight = true;
    try {
      final lang = _isArabic() ? 'ar' : 'en';

      final HttpsCallableResult<Object?> resp;
      try {
        resp = await _functions
            .httpsCallable('createFeaturePropertyMyFatoorahPayment')
            .call<Object?>(<String, dynamic>{
          'propertyId': propertyId,
          'durationDays': durationDays,
          'amountKwd': amountKwd,
          'lang': lang,
        });
      } on FirebaseFunctionsException catch (e) {
        debugPrint('MF_CREATE_FEATURE_SESSION_FAILED ${e.code} ${e.message}');
        return const FeaturedAdPaymentUiResult(
          success: false,
          failure: FeaturedAdPaymentFailure.sessionCreateFailed,
        );
      } catch (e) {
        debugPrint('MF_CREATE_FEATURE_SESSION_FAILED $e');
        return const FeaturedAdPaymentUiResult(
          success: false,
          failure: FeaturedAdPaymentFailure.sessionCreateFailed,
        );
      }

      final data = (resp.data as Map?) ?? const <Object?, Object?>{};
      final paymentUrl = (data['paymentUrl'] as String?)?.trim() ?? '';
      final paymentId = (data['paymentId'] as String?)?.trim() ?? '';
      if (paymentUrl.isEmpty || paymentId.isEmpty) {
        return const FeaturedAdPaymentUiResult(
          success: false,
          failure: FeaturedAdPaymentFailure.sessionCreateFailed,
        );
      }

      final result = await _runCheckout(
        paymentUrl: paymentUrl,
        paymentId: paymentId,
        successHostPath: 'payment/feature/success',
        errorHostPath: 'payment/feature/error',
      );
      if (result == null) {
        return const FeaturedAdPaymentUiResult(
          success: false,
          failure: FeaturedAdPaymentFailure.sessionCreateFailed,
        );
      }
      if (!result.success) {
        return FeaturedAdPaymentUiResult(
          success: false,
          failure: result.userAborted
              ? FeaturedAdPaymentFailure.userCancelled
              : FeaturedAdPaymentFailure.gatewayError,
        );
      }
      return FeaturedAdPaymentUiResult(
        success: true,
        failure: FeaturedAdPaymentFailure.none,
        paymentId: result.paymentId,
      );
    } finally {
      _featureSessionInFlight = false;
    }
  }
}
