import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/widgets/property_details_page.dart';
import 'package:aqarai_app/models/listing_enums.dart';

class MyBookingsPage extends StatelessWidget {
  const MyBookingsPage({super.key});

  String _statusLabel(String raw, bool isAr) {
    final s = raw.trim().toLowerCase();
    switch (s) {
      case 'pending_payment':
        return isAr ? 'بانتظار الدفع' : 'Awaiting payment';
      case 'confirmed':
        return isAr ? 'مؤكد' : 'Confirmed';
      case 'cancelled':
        return isAr ? 'ملغي' : 'Cancelled';
      default:
        return raw.isEmpty ? '-' : raw;
    }
  }

  String _fmtDate(Timestamp? ts, String locale) {
    if (ts == null) return '-';
    return DateFormat('yyyy/MM/dd', locale).format(ts.toDate());
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final localeStr = Localizations.localeOf(context).toString();
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null || uid.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(isAr ? 'حجوزاتي' : 'My bookings')),
        body: Center(
          child: Text(isAr ? 'سجّل الدخول لعرض الحجوزات' : 'Sign in to view bookings'),
        ),
      );
    }

    final q = FirebaseFirestore.instance
        .collection('bookings')
        .where('clientId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(50);

    return Scaffold(
      appBar: AppBar(title: Text(isAr ? 'حجوزاتي' : 'My bookings')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(
              child: Text(isAr ? 'لا توجد حجوزات بعد' : 'No bookings yet'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final d = docs[i].data();
              final propertyId = (d['propertyId'] ?? '').toString().trim();
              final status = (d['status'] ?? '').toString().trim();
              final start = d['startDate'] as Timestamp?;
              final end = d['endDate'] as Timestamp?;
              final totalPrice = d['totalPrice'];
              final currency = (d['currency'] ?? 'KWD').toString().trim();
              final priceLabel = totalPrice is num
                  ? '${NumberFormat.decimalPattern(localeStr).format(totalPrice)} $currency'
                  : '-';

              return Card(
                child: ListTile(
                  title: Text(
                    propertyId.isNotEmpty ? propertyId : '-',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    '${_fmtDate(start, localeStr)} → ${_fmtDate(end, localeStr)}\n'
                    '${isAr ? 'الحالة' : 'Status'}: ${_statusLabel(status, isAr)}',
                  ),
                  trailing: Text(
                    priceLabel,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  onTap: propertyId.isEmpty
                      ? null
                      : () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => PropertyDetailsPage(
                                propertyId: propertyId,
                                leadSource: DealLeadSource.direct,
                              ),
                            ),
                          );
                        },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

