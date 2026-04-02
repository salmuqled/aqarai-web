import 'package:cloud_firestore/cloud_firestore.dart';

/// Firestore collection: `invoices` (server-generated; admin read-only in app).
abstract final class InvoiceFields {
  InvoiceFields._();

  static const String collection = 'invoices';

  static const String id = 'id';
  static const String invoiceNumber = 'invoiceNumber';
  static const String paymentId = 'paymentId';
  static const String companyId = 'companyId';
  static const String companyName = 'companyName';
  static const String amount = 'amount';
  static const String serviceType = 'serviceType';
  static const String area = 'area';
  static const String description = 'description';
  static const String status = 'status';
  static const String createdAt = 'createdAt';
  static const String pdfUrl = 'pdfUrl';
  static const String pdfError = 'pdfError';
  static const String pdfErrorAt = 'pdfErrorAt';
  static const String emailSent = 'emailSent';
  static const String emailError = 'emailError';
  static const String emailSentAt = 'emailSentAt';
  static const String emailAttemptAt = 'emailAttemptAt';
  static const String paidAt = 'paidAt';
  static const String cancelledAt = 'cancelledAt';
  static const String cancelReason = 'cancelReason';
}

/// Invoice lifecycle (Firestore `status`).
abstract final class InvoiceLifecycleStatus {
  InvoiceLifecycleStatus._();

  static const String issued = 'issued';
  static const String paid = 'paid';
  static const String cancelled = 'cancelled';

  static const List<String> values = [issued, paid, cancelled];
}

abstract final class InvoiceServiceType {
  InvoiceServiceType._();

  static const String rent = 'rent';
  static const String sale = 'sale';
  static const String chalet = 'chalet';

  static const List<String> values = [rent, sale, chalet];
}

/// Parsed invoice row for admin UI.
class Invoice {
  const Invoice({
    required this.docId,
    required this.invoiceNumber,
    required this.companyName,
    required this.amount,
    required this.serviceType,
    required this.area,
    required this.description,
    required this.status,
    required this.createdAt,
    required this.pdfUrl,
    this.paymentId,
    this.companyId,
    this.pdfError,
    this.pdfErrorAt,
    this.emailSent,
    this.emailError,
    this.emailSentAt,
    this.emailAttemptAt,
    this.paidAt,
    this.cancelledAt,
    this.cancelReason,
  });

  final String docId;
  final String invoiceNumber;
  final String companyName;
  final double amount;
  final String serviceType;
  final String area;
  final String description;
  /// Raw Firestore status; may be legacy empty → treat as [InvoiceLifecycleStatus.paid] if PDF exists.
  final String status;
  final Timestamp? createdAt;
  final String pdfUrl;
  final String? paymentId;
  final String? companyId;
  final String? pdfError;
  final Timestamp? pdfErrorAt;
  final bool? emailSent;
  final String? emailError;
  final Timestamp? emailSentAt;
  final Timestamp? emailAttemptAt;
  final Timestamp? paidAt;
  final Timestamp? cancelledAt;
  final String? cancelReason;

  /// Normalized label for UI (issued / paid / cancelled).
  String get displayStatus {
    final s = status.trim().toLowerCase();
    if (s.isEmpty && pdfUrl.trim().length > 8) {
      return InvoiceLifecycleStatus.paid;
    }
    if (InvoiceLifecycleStatus.values.contains(s)) return s;
    if (s == 'paid') return InvoiceLifecycleStatus.paid;
    return s.isEmpty ? InvoiceLifecycleStatus.issued : s;
  }

  static Invoice fromFirestore(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? {};
    double amt = 0;
    final raw = m[InvoiceFields.amount];
    if (raw is num) {
      amt = raw.toDouble();
    } else if (raw != null) {
      amt = double.tryParse(raw.toString()) ?? 0;
    }

    bool? emailSentVal;
    final es = m[InvoiceFields.emailSent];
    if (es is bool) emailSentVal = es;

    return Invoice(
      docId: d.id,
      invoiceNumber: '${m[InvoiceFields.invoiceNumber] ?? ''}',
      companyName: '${m[InvoiceFields.companyName] ?? ''}',
      amount: amt,
      serviceType: '${m[InvoiceFields.serviceType] ?? ''}',
      area: '${m[InvoiceFields.area] ?? ''}',
      description: '${m[InvoiceFields.description] ?? ''}',
      status: '${m[InvoiceFields.status] ?? ''}',
      createdAt: m[InvoiceFields.createdAt] as Timestamp?,
      pdfUrl: '${m[InvoiceFields.pdfUrl] ?? ''}',
      paymentId: m[InvoiceFields.paymentId] as String?,
      companyId: m[InvoiceFields.companyId] as String?,
      pdfError: m[InvoiceFields.pdfError] as String?,
      pdfErrorAt: m[InvoiceFields.pdfErrorAt] as Timestamp?,
      emailSent: emailSentVal,
      emailError: m[InvoiceFields.emailError] as String?,
      emailSentAt: m[InvoiceFields.emailSentAt] as Timestamp?,
      emailAttemptAt: m[InvoiceFields.emailAttemptAt] as Timestamp?,
      paidAt: m[InvoiceFields.paidAt] as Timestamp?,
      cancelledAt: m[InvoiceFields.cancelledAt] as Timestamp?,
      cancelReason: m[InvoiceFields.cancelReason] as String?,
    );
  }
}

/// Dashboard totals from `financial_ledger` (source of truth for revenue).
class InvoiceGlobalSummary {
  const InvoiceGlobalSummary({
    required this.totalRevenueKwd,
    required this.ledgerEntryCount,
    required this.thisMonthRevenueKwd,
  });

  final double totalRevenueKwd;
  final int ledgerEntryCount;
  final double thisMonthRevenueKwd;
}
