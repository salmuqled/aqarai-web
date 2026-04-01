import 'package:cloud_functions/cloud_functions.dart';

/// Calls [markAuctionFeePaid] (us-central1). Authoritative Firestore update for fee status.
abstract final class MarkAuctionFeePaidService {
  MarkAuctionFeePaidService._();

  static const String _region = 'us-central1';
  static const String _callableName = 'markAuctionFeePaid';

  static Future<MarkAuctionFeePaidResult> call({
    required String requestId,
  }) async {
    final trimmed = requestId.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('requestId is required');
    }
    final fn = FirebaseFunctions.instanceFor(
      region: _region,
    ).httpsCallable(_callableName);
    final res = await fn.call<Map<String, dynamic>>({'requestId': trimmed});
    final data = res.data;
    final ok = data['ok'] == true;
    final ref = data['paymentReference']?.toString();
    return MarkAuctionFeePaidResult(
      ok: ok,
      paymentReference: ref != null && ref.isNotEmpty ? ref : null,
    );
  }
}

class MarkAuctionFeePaidResult {
  const MarkAuctionFeePaidResult({
    required this.ok,
    this.paymentReference,
  });

  final bool ok;
  final String? paymentReference;
}
