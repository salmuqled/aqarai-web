import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/pages/admin_deal_detail_page.dart';
import 'package:aqarai_app/utils/admin_deal_status_label.dart';
import 'package:aqarai_app/utils/deal_followup_filters.dart';

/// Deals from the dashboard sample whose [nextFollowUpAt] is due and status is active.
class AdminFollowupSection extends StatelessWidget {
  const AdminFollowupSection({
    super.key,
    required this.dealDocs,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> dealDocs;

  static String _propertyTitle(Map<String, dynamic> m) {
    final t = (m['propertyTitle'] ?? m['title'] ?? '').toString().trim();
    return t.isEmpty ? '—' : t;
  }

  static String? _lastNoteText(Map<String, dynamic> m) {
    final raw = m['notes'];
    if (raw is! List || raw.isEmpty) return null;
    Timestamp? bestTs;
    String? bestText;
    for (final e in raw) {
      if (e is! Map) continue;
      final map = Map<String, dynamic>.from(e);
      final text = map['text']?.toString().trim() ?? '';
      if (text.isEmpty) continue;
      final t = map['createdAt'];
      if (t is! Timestamp) continue;
      if (bestTs == null || t.compareTo(bestTs) > 0) {
        bestTs = t;
        bestText = text;
      }
    }
    return bestText;
  }

  static List<QueryDocumentSnapshot<Map<String, dynamic>>> _dueSorted(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final list = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final d in docs) {
      try {
        final m = d.data();
        if (!isDealFollowUpDueNow(m)) continue;
        list.add(d);
      } catch (_) {
        continue;
      }
    }
    list.sort((a, b) {
      final ta = a.data()['nextFollowUpAt'];
      final tb = b.data()['nextFollowUpAt'];
      if (ta is Timestamp && tb is Timestamp) return ta.compareTo(tb);
      return 0;
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final due = _dueSorted(dealDocs);
    final accent = Colors.deepOrange.shade700;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.alarm_on_outlined, color: accent, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  loc.adminFollowupSectionTitle,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.navy,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            loc.adminFollowupSectionSubtitle,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 14),
          if (due.isEmpty)
            Text(
              loc.adminFollowupEmpty,
              style: TextStyle(color: Colors.grey.shade700),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: due.length > 12 ? 12 : due.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final doc = due[i];
                final m = doc.data();
                final title = _propertyTitle(m);
                final phone = (m['clientPhone'] ?? '').toString().trim();
                final st = m['dealStatus']?.toString().trim() ?? '';
                final lastNote = _lastNoteText(m);
                return Material(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => AdminDealDetailPage(dealId: doc.id),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          if (phone.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              phone,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            '${loc.adminDealPipelineStatus}: ${getDealStatusLabel(context, st)}',
                            style: TextStyle(
                              fontSize: 13,
                              color: accent,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (lastNote != null && lastNote.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              loc.adminFollowupLastNoteLabel,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              lastNote,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade900,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          if (due.length > 12)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                isAr ? 'عرض أول ١٢ صفقة' : 'Showing first 12 deals',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ),
        ],
      ),
    );
  }
}
