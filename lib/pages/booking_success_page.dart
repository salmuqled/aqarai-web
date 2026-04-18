import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/pages/my_bookings_page.dart';
import 'package:aqarai_app/pages/invoice_viewer_page.dart';
import 'package:aqarai_app/pages/invoices_page.dart';

class BookingSuccessPage extends StatelessWidget {
  const BookingSuccessPage({
    super.key,
    required this.propertyId,
    required this.startDate,
    required this.endDate,
    required this.totalDays,
    required this.totalPrice,
    this.currencyCode = 'KWD',
    this.bookingId,
    this.confirmedAfterPayment = false,
  });

  final String propertyId;
  final DateTime startDate;
  final DateTime endDate;
  final int totalDays;
  final double totalPrice;
  final String currencyCode;
  final String? bookingId;

  /// When true, payment was verified server-side and booking is `confirmed`.
  final bool confirmedAfterPayment;

  String _fmtDate(DateTime d, String locale) =>
      DateFormat('yyyy/MM/dd', locale).format(d);

  String _propertyTitleFrom(Map<String, dynamic>? d, bool isAr) {
    if (d == null) return propertyId;
    final area =
        (isAr ? (d['areaAr'] ?? d['area']) : (d['areaEn'] ?? d['area'])) ??
            '';
    final type = (d['type'] ?? '').toString().trim();
    final title = '${area.toString().trim()}${type.isNotEmpty ? ' • $type' : ''}'
        .trim();
    return title.isNotEmpty ? title : propertyId;
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final localeStr = Localizations.localeOf(context).toString();
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');

    final totalLabel = '${fmt.format(totalPrice)} $currencyCode';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          confirmedAfterPayment
              ? (isAr ? 'تم تأكيد الحجز' : 'Booking confirmed')
              : (isAr ? 'تم الحجز' : 'Booking'),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              elevation: 0,
              color: Colors.green.shade50,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.green.shade200),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green.shade700),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        confirmedAfterPayment
                            ? (isAr ? 'تم تأكيد الحجز' : 'Your booking is confirmed')
                            : (isAr
                                ? 'تم استلام طلب الحجز'
                                : 'Booking request received'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (!confirmedAfterPayment)
              Text(
                isAr
                    ? 'سيتم تأكيد الحجز بعد الدفع.'
                    : 'Your booking will be confirmed after payment.',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            if (!confirmedAfterPayment) const SizedBox(height: 12),

            FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              future: FirebaseFirestore.instance
                  .collection('properties')
                  .doc(propertyId)
                  .get(),
              builder: (context, snap) {
                final title = _propertyTitleFrom(snap.data?.data(), isAr);
                return Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (bookingId != null &&
                            bookingId!.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'bookingId: ${bookingId!.trim()}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        _kv(
                          isAr ? 'تاريخ الوصول' : 'Check-in',
                          _fmtDate(startDate, localeStr),
                        ),
                        const SizedBox(height: 8),
                        _kv(
                          isAr ? 'تاريخ المغادرة' : 'Check-out',
                          _fmtDate(endDate, localeStr),
                        ),
                        const SizedBox(height: 8),
                        _kv(
                          isAr ? 'عدد الأيام' : 'Total days',
                          '$totalDays',
                        ),
                        const SizedBox(height: 8),
                        _kv(
                          isAr ? 'الإجمالي' : 'Total',
                          totalLabel,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            if (bookingId != null && bookingId!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('bookings')
                    .doc(bookingId!.trim())
                    .snapshots(),
                builder: (context, snap) {
                  final isLoading = snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData;
                  final data = snap.data?.data();
                  final invoiceUrl = (data?['invoiceUrl'] ?? '').toString().trim();

                  final bool ready = invoiceUrl.length > 12;

                  return Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.grey.shade300),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.receipt_long_outlined,
                                color: ready
                                    ? Colors.green.shade700
                                    : Colors.grey.shade700,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  isAr ? 'الفاتورة' : 'Invoice',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            ready
                                ? (isAr
                                    ? 'الفاتورة جاهزة للعرض.'
                                    : 'Your invoice is ready.')
                                : (isLoading
                                    ? (isAr
                                        ? 'جاري تجهيز الفاتورة...'
                                        : 'Invoice is being prepared...')
                                    : (isAr
                                        ? 'جاري تجهيز الفاتورة...'
                                        : 'Invoice is being prepared...')),
                            style: TextStyle(
                              color: Colors.grey.shade700,
                              height: 1.35,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: ready
                                  ? () {
                                      Navigator.of(context).push<void>(
                                        MaterialPageRoute<void>(
                                          builder: (_) => InvoiceViewerPage(
                                            invoiceUrl: invoiceUrl,
                                          ),
                                        ),
                                      );
                                    }
                                  : null,
                              icon: const Icon(Icons.picture_as_pdf_outlined),
                              label: Text(
                                isAr ? 'عرض الفاتورة' : 'View Invoice',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],

            const Spacer(),

            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(builder: (_) => const MyBookingsPage()),
                );
              },
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(isAr ? 'عرض حجوزاتي' : 'My bookings'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(builder: (_) => const InvoicesPage()),
                );
              },
              icon: const Icon(Icons.receipt_long_outlined),
              label: Text(isAr ? 'الفواتير' : 'Invoices'),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () {
                Navigator.of(context).popUntil((r) => r.isFirst);
              },
              child: Text(isAr ? 'العودة للرئيسية' : 'Back to Home'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static Widget _kv(String k, String v) {
    return Row(
      children: [
        Expanded(
          child: Text(
            k,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
        Text(
          v,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

