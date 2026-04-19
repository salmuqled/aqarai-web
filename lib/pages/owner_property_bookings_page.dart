import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Owner: confirmed/pending bookings for a single chalet listing.
class OwnerPropertyBookingsPage extends StatelessWidget {
  const OwnerPropertyBookingsPage({super.key, required this.propertyId});

  final String propertyId;

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

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final localeStr = Localizations.localeOf(context).toString();
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null || uid.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: Text(isAr ? 'حجوزات الشاليه' : 'Chalet bookings'),
        ),
        body: Center(
          child: Text(isAr ? 'سجّل الدخول' : 'Sign in required'),
        ),
      );
    }

    final q = FirebaseFirestore.instance
        .collection('bookings')
        .where('propertyId', isEqualTo: propertyId)
        .orderBy('createdAt', descending: true)
        .limit(80);

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'حجوزات الشاليه' : 'Chalet bookings'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  snap.error.toString(),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final docs = (snap.data?.docs ?? []).where((d) {
            final m = d.data();
            return (m['ownerId']?.toString() ?? '') == uid;
          }).toList();
          if (docs.isEmpty) {
            return Center(
              child: Text(isAr ? 'لا توجد حجوزات لهذا الإعلان' : 'No bookings for this listing'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final d = docs[i].data();
              final status = (d['status'] ?? '').toString().trim();
              final start = d['startDate'] as Timestamp?;
              final end = d['endDate'] as Timestamp?;
              final totalPrice = d['totalPrice'];
              final currency = (d['currency'] ?? 'KWD').toString().trim();
              final priceLabel = totalPrice is num
                  ? '${NumberFormat.decimalPattern(localeStr).format(totalPrice)} $currency'
                  : '-';
              final fmt = DateFormat.yMMMd(localeStr);
              final range = start != null && end != null
                  ? '${fmt.format(start.toDate())} → ${fmt.format(end.toDate())}'
                  : '-';
              return Card(
                child: ListTile(
                  title: Text(range),
                  subtitle: Text('${_statusLabel(status, isAr)} · $priceLabel'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
