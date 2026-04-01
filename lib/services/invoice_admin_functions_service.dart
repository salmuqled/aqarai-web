import 'package:cloud_functions/cloud_functions.dart';

/// Admin HTTPS callables for invoice operations (region matches Cloud Functions).
abstract final class InvoiceAdminFunctionsService {
  InvoiceAdminFunctionsService._();

  static FirebaseFunctions _f() =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  static Future<Map<String, dynamic>> resendInvoiceEmail(String invoiceId) async {
    final callable = _f().httpsCallable('resendInvoiceEmail');
    final result = await callable.call(<String, dynamic>{'invoiceId': invoiceId});
    final raw = result.data;
    if (raw == null) return {};
    return Map<String, dynamic>.from(raw as Map);
  }

  static Future<Map<String, dynamic>> retryInvoicePdf(String invoiceId) async {
    final callable = _f().httpsCallable('retryInvoicePdf');
    final result = await callable.call(<String, dynamic>{'invoiceId': invoiceId});
    final raw = result.data;
    if (raw == null) return {};
    return Map<String, dynamic>.from(raw as Map);
  }
}
