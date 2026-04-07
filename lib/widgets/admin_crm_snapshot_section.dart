import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/constants/deal_constants.dart';

/// Interest-button leads in the dashboard deals sample: totals for quick CRM view.
class AdminCrmSnapshotSection extends StatelessWidget {
  const AdminCrmSnapshotSection({
    super.key,
    required this.dealDocs,
    required this.isAr,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;
  final bool isAr;

  static bool _isInterestLead(Map<String, dynamic> m) {
    final src = (m['interestSource'] ?? '').toString();
    return src == 'property_detail' || src == 'wanted_detail';
  }

  @override
  Widget build(BuildContext context) {
    final leads = dealDocs.map((d) => d.data()).where(_isInterestLead).toList();

    final total = leads.length;
    var active = 0;
    var closed = 0;
    for (final m in leads) {
      final st = (m['dealStatus'] ?? '').toString().trim();
      if (st == DealStatus.closed) closed++;
      if (st != DealStatus.closed && st != DealStatus.notInterested) {
        active++;
      }
    }

    Widget metricCard({
      required String label,
      required String value,
      required IconData icon,
    }) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.navy, size: 22),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isAr ? 'لمحة CRM (المهتمون)' : 'CRM snapshot (interested leads)',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          isAr
              ? 'من عيّنة الصفقات في لوحة التحكم (زر أنا مهتم)'
              : 'From the dashboard deals sample (Interested button)',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 520;
            final c1 = metricCard(
              label: isAr ? 'إجمالي المهتمين' : 'Total leads',
              value: '$total',
              icon: Icons.groups_outlined,
            );
            final c2 = metricCard(
              label: isAr ? 'صفقات نشطة' : 'Active deals',
              value: '$active',
              icon: Icons.trending_up_outlined,
            );
            final c3 = metricCard(
              label: isAr ? 'مغلقة' : 'Closed deals',
              value: '$closed',
              icon: Icons.check_circle_outline,
            );
            if (wide) {
              return Row(
                children: [
                  Expanded(child: c1),
                  const SizedBox(width: 10),
                  Expanded(child: c2),
                  const SizedBox(width: 10),
                  Expanded(child: c3),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                c1,
                const SizedBox(height: 10),
                c2,
                const SizedBox(height: 10),
                c3,
              ],
            );
          },
        ),
      ],
    );
  }
}
