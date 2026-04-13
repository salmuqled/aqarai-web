import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/services/ai_suggestions_auto_config_service.dart';

/// Last N entries from [ai_config_history].
class AdminAiConfigHistorySection extends StatefulWidget {
  const AdminAiConfigHistorySection({super.key, required this.isAr});

  final bool isAr;

  @override
  State<AdminAiConfigHistorySection> createState() =>
      _AdminAiConfigHistorySectionState();
}

class _AdminAiConfigHistorySectionState extends State<AdminAiConfigHistorySection> {
  String? _restoringDocId;

  late final Stream<QuerySnapshot<Map<String, dynamic>>> _historyStream =
      AiSuggestionsAutoConfigService.historyQuery().snapshots();

  bool get isAr => widget.isAr;

  static String _relTime(Timestamp? t, bool isAr) {
    if (t == null) return isAr ? '—' : '—';
    final d = t.toDate();
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 60) return isAr ? 'منذ ${diff.inMinutes} د' : '${diff.inMinutes}m ago';
    if (diff.inHours < 48) return isAr ? 'منذ ${diff.inHours} س' : '${diff.inHours}h ago';
    return isAr ? 'منذ ${diff.inDays} يوم' : '${diff.inDays}d ago';
  }

  Future<void> _confirmAndRestore(
    BuildContext context, {
    required String docId,
    required int version,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'استعادة الإعداد؟' : 'Restore configuration?'),
        content: Text(
          isAr
              ? 'سيتم استرجاع إعدادات الاقتراحات من الإصدار v$version إلى المستند الحالي. سيُسجَّل إصدار جديد في السجل.'
              : 'Replace the live AI suggestions config with the saved snapshot from version v$version? A new config version will be recorded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isAr ? 'استعادة' : 'Restore'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    setState(() => _restoringDocId = docId);
    try {
      await AiSuggestionsAutoConfigService.restoreConfigFromHistory(
        historyDocId: docId,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr ? 'تمت الاستعادة من v$version.' : 'Restored from v$version.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr ? 'فشلت الاستعادة: $e' : 'Restore failed: $e',
          ),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _restoringDocId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _historyStream,
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(
            isAr ? 'تعذر تحميل السجل: ${snap.error}' : 'History error: ${snap.error}',
            style: TextStyle(color: Colors.red.shade800),
          );
        }
        final docs = snap.data?.docs ?? const [];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isAr ? 'سجل تغييرات الإعداد' : 'Config change log',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.navy,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isAr
                  ? 'آخر 10 تعديلات — ai_config_history'
                  : 'Last 10 changes — ai_config_history',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 10),
            if (snap.connectionState == ConnectionState.waiting && docs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (docs.isEmpty)
              Text(
                isAr ? 'لا يوجد سجل بعد.' : 'No history yet.',
                style: TextStyle(color: Colors.grey.shade700),
              )
            else
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: docs.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: Colors.grey.shade200),
                  itemBuilder: (context, i) {
                    final m = docs[i].data();
                    final ver = (m['configVersion'] as num?)?.toInt() ?? 0;
                    final by = (m['updatedBy'] ?? '').toString();
                    final sum = (m['changeSummary'] ?? '').toString();
                    final ca = m['createdAt'] as Timestamp?;
                    final byLabel = by == AiSuggestionsAutoConfig.updatedBySystemAutoTune
                        ? (isAr ? 'النظام' : 'System')
                        : (isAr ? 'مسؤول' : 'Admin');
                    final histId = docs[i].id;
                    final busy = _restoringDocId == histId;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      title: Text(
                        isAr
                            ? 'الإصدار v$ver — $byLabel'
                            : 'v$ver — $byLabel',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text(
                            _relTime(ca, isAr),
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                          ),
                          if (sum.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            SelectableText(
                              sum,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.3,
                                color: Colors.grey.shade900,
                              ),
                            ),
                          ],
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (m['snapshot'] is Map)
                            TextButton(
                              onPressed: busy || _restoringDocId != null
                                  ? null
                                  : () => _confirmAndRestore(
                                        context,
                                        docId: histId,
                                        version: ver,
                                      ),
                              child: busy
                                  ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.navy,
                                      ),
                                    )
                                  : Text(isAr ? 'استعادة' : 'Restore'),
                            ),
                          Tooltip(
                            message: by.isNotEmpty ? by : '',
                            child: Icon(Icons.receipt_long_outlined, color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}
