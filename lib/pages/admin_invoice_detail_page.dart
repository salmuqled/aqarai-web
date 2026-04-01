import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/invoice.dart';
import 'package:aqarai_app/services/invoice_admin_functions_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

/// Admin-only: read-only invoice detail, PDF link, resend email, retry PDF.
class AdminInvoiceDetailPage extends StatefulWidget {
  const AdminInvoiceDetailPage({super.key, required this.invoiceId});

  final String invoiceId;

  static const Color _navy = Color(0xFF0D2B4D);

  @override
  State<AdminInvoiceDetailPage> createState() => _AdminInvoiceDetailPageState();
}

class _AdminInvoiceDetailPageState extends State<AdminInvoiceDetailPage> {
  bool _resendBusy = false;
  bool _retryBusy = false;

  Future<void> _openPdf(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      throw StateError('launch_failed');
    }
  }

  String _emailSentLabel(AppLocalizations loc, Invoice inv) {
    if (inv.emailSent == true) return loc.adminInvoiceEmailSentYes;
    if (inv.emailSent == false) return loc.adminInvoiceEmailSentNo;
    return '—';
  }

  String _ts(Timestamp? ts) {
    if (ts == null) return '—';
    return DateFormat.yMMMd().add_Hm().format(ts.toDate());
  }

  Future<void> _onResend(AppLocalizations loc) async {
    if (_resendBusy) return;
    setState(() => _resendBusy = true);
    try {
      await InvoiceAdminFunctionsService.resendInvoiceEmail(widget.invoiceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.adminInvoiceResendQueued)),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? e.code)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _resendBusy = false);
    }
  }

  Future<void> _onRetryPdf(AppLocalizations loc) async {
    if (_retryBusy) return;
    setState(() => _retryBusy = true);
    try {
      await InvoiceAdminFunctionsService.retryInvoicePdf(widget.invoiceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.adminInvoiceRetryPdfOk)),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? e.code)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _retryBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        title: Text(loc.adminInvoiceDetailTitle),
        backgroundColor: AdminInvoiceDetailPage._navy,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection(InvoiceFields.collection)
            .doc(widget.invoiceId)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final doc = snap.data;
          if (doc == null || !doc.exists) {
            return Center(child: Text(loc.adminInvoicesError));
          }
          final inv = Invoice.fromFirestore(doc);

          final dateStr = inv.createdAt != null
              ? DateFormat.yMMMd().add_Hm().format(inv.createdAt!.toDate())
              : '—';

          final pdfReady = inv.pdfUrl.trim().length > 12;
          final cancelled =
              inv.displayStatus == InvoiceLifecycleStatus.cancelled;
          final showRetry = (inv.pdfError != null &&
                  inv.pdfError!.trim().isNotEmpty) ||
              !pdfReady;

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            children: [
              _DetailCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      inv.invoiceNumber,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AdminInvoiceDetailPage._navy,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      inv.companyName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _DetailCard(
                child: _rows([
                  _row(loc.adminInvoiceFieldAmount,
                      _fmtKwd(inv.amount, isAr)),
                  _row(loc.adminInvoiceFieldServiceType, inv.serviceType),
                  _row(loc.adminInvoiceFieldArea, inv.area),
                  _row(loc.adminInvoiceFieldDescription, inv.description),
                  _row(
                    loc.adminInvoiceFieldStatus,
                    inv.displayStatus.toUpperCase(),
                  ),
                  _row(loc.adminInvoiceFieldDate, dateStr),
                  if (inv.paidAt != null)
                    _row(loc.adminInvoiceFieldPaidAt, _ts(inv.paidAt)),
                  if (inv.paymentId != null && inv.paymentId!.isNotEmpty)
                    _row(loc.adminInvoiceFieldPaymentId, inv.paymentId!),
                  _row(loc.adminInvoiceFieldEmailSent, _emailSentLabel(loc, inv)),
                  if (inv.emailError != null && inv.emailError!.trim().isNotEmpty)
                    _row(loc.adminInvoiceFieldEmailError, inv.emailError!),
                  if (inv.emailSentAt != null)
                    _row(loc.adminInvoiceFieldEmailSentAt, _ts(inv.emailSentAt)),
                  if (inv.emailAttemptAt != null)
                    _row(
                      loc.adminInvoiceFieldEmailAttemptAt,
                      _ts(inv.emailAttemptAt),
                    ),
                  if (inv.pdfError != null && inv.pdfError!.trim().isNotEmpty)
                    _row(loc.adminInvoiceFieldPdfError, inv.pdfError!),
                  if (inv.pdfErrorAt != null)
                    _row(loc.adminInvoiceFieldPdfErrorAt, _ts(inv.pdfErrorAt)),
                ]),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: cancelled || _resendBusy
                          ? null
                          : () => _onResend(loc),
                      icon: _resendBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.outgoing_mail),
                      label: Text(loc.adminInvoiceActionResendEmail),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: cancelled || _retryBusy || !showRetry
                          ? null
                          : () => _onRetryPdf(loc),
                      icon: _retryBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(loc.adminInvoiceActionRetryPdf),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AdminInvoiceDetailPage._navy,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: pdfReady
                    ? () async {
                        try {
                          await _openPdf(inv.pdfUrl);
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content:
                                    Text(loc.adminInvoicesCouldNotOpenPdf),
                              ),
                            );
                          }
                        }
                      }
                    : null,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(
                  pdfReady
                      ? loc.adminInvoiceDetailDownload
                      : loc.adminInvoiceDetailNoPdf,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _fmtKwd(double n, bool isAr) {
    final s = n == n.roundToDouble()
        ? n.toStringAsFixed(0)
        : n.toStringAsFixed(3);
    return isAr ? '$s د.ك' : '$s KWD';
  }

  static Widget _rows(List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _withDividers(children),
    );
  }

  static List<Widget> _withDividers(List<Widget> children) {
    final out = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      out.add(children[i]);
      if (i < children.length - 1) {
        out.add(Divider(height: 22, color: Colors.grey.shade200));
      }
    }
    return out;
  }

  static Widget _row(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1a1a1a),
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(padding: const EdgeInsets.all(18), child: child),
    );
  }
}
