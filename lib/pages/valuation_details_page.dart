import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/services/firestore.dart';

/// صفحة تفاصيل طلب التقييم العقاري — للأدمن
class ValuationDetailsPage extends StatelessWidget {
  final String valuationId;

  const ValuationDetailsPage({
    super.key,
    required this.valuationId,
  });

  String _fmtDate(Timestamp? ts) {
    if (ts == null) return '-';
    final dt = ts.toDate();
    return '${dt.year}/${dt.month}/${dt.day} – ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _callPhone(BuildContext context, String raw) async {
    final phone = raw.trim();
    if (phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openWhatsApp(BuildContext context, String raw) async {
    final phone = raw.replaceAll('+', '').trim();
    if (phone.isEmpty) return;
    final uri = Uri.parse('https://wa.me/$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'تفاصيل طلب التقييم' : 'Valuation request details'),
        centerTitle: true,
      ),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: firestore.collection('valuations').doc(valuationId).get(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || !snap.hasData || !snap.data!.exists) {
            return Center(
              child: Text(
                isAr ? 'الطلب غير موجود' : 'Request not found',
              ),
            );
          }

          final d = snap.data!.data()!;
          final ownerName = (d['ownerName'] ?? '-').toString();
          final phone = (d['phone'] ?? '').toString();
          final governorate = (d['governorate'] ?? '-').toString();
          final area = (d['area'] ?? '-').toString();
          final propertyType = (d['propertyType'] ?? '-').toString();
          final propertyArea = (d['propertyArea'] ?? '-').toString();
          final buildYear = (d['buildYear'] ?? '-').toString();
          final condition = (d['condition'] ?? '-').toString();
          final purpose = (d['purpose'] ?? '-').toString();
          final notes = (d['notes'] ?? '-').toString();
          final createdAt = d['createdAt'] as Timestamp?;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _row(loc.valuation_ownerName, ownerName),
                        const SizedBox(height: 12),
                        _row(loc.valuation_phone, phone.isEmpty ? '-' : phone),
                        const SizedBox(height: 12),
                        _row(loc.valuation_governorate, governorate),
                        const SizedBox(height: 12),
                        _row(loc.valuation_area, area),
                        const SizedBox(height: 12),
                        _row(loc.valuation_propertyType, propertyType),
                        const SizedBox(height: 12),
                        _row(loc.valuation_propertyArea, propertyArea),
                        const SizedBox(height: 12),
                        _row(loc.valuation_buildYear, buildYear),
                        const SizedBox(height: 12),
                        _row(loc.valuation_condition, condition),
                        const SizedBox(height: 12),
                        _row(loc.valuation_purpose, purpose),
                        if (notes.isNotEmpty && notes != '-') ...[
                          const SizedBox(height: 12),
                          _row(loc.valuation_notes, notes),
                        ],
                        const SizedBox(height: 12),
                        _row(loc.addedOn, _fmtDate(createdAt)),
                      ],
                    ),
                  ),
                ),
                if (phone.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _callPhone(context, phone),
                          icon: const Icon(Icons.call, color: Colors.green),
                          label: Text(
                            isAr ? 'اتصال' : 'Call',
                            style: const TextStyle(color: Colors.green),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.green),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openWhatsApp(context, phone),
                          icon: const Icon(Icons.chat, color: Colors.green),
                          label: Text(
                            'WhatsApp',
                            style: const TextStyle(color: Colors.green),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.green),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey,
            ),
          ),
        ),
        Expanded(
          child: Text(value),
        ),
      ],
    );
  }
}
