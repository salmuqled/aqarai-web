import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';

enum _SeverityFilter { all, high, medium, low }

class AdminSystemIssuesSection extends StatefulWidget {
  const AdminSystemIssuesSection({super.key, required this.isAr});

  final bool isAr;

  @override
  State<AdminSystemIssuesSection> createState() => _AdminSystemIssuesSectionState();
}

class _AdminSystemIssuesSectionState extends State<AdminSystemIssuesSection> {
  _SeverityFilter _filter = _SeverityFilter.all;

  static const int _limit = 80;

  String _sevLabel(String s) {
    final isAr = widget.isAr;
    switch (s.toLowerCase()) {
      case 'high':
        return isAr ? 'عالي' : 'High';
      case 'medium':
        return isAr ? 'متوسط' : 'Medium';
      case 'low':
        return isAr ? 'منخفض' : 'Low';
      default:
        return s;
    }
  }

  String _typeLabel(String t) {
    final isAr = widget.isAr;
    switch (t) {
      case 'invoice_pdf_failed':
        return isAr ? 'فشل PDF فاتورة' : 'Invoice PDF failed';
      case 'email_failed':
        return isAr ? 'فشل بريد' : 'Email failed';
      case 'ledger_error':
        return isAr ? 'خطأ دفتر' : 'Ledger error';
      default:
        return t;
    }
  }

  bool _passesFilter(Map<String, dynamic> m) {
    if (_filter == _SeverityFilter.all) return true;
    final s = (m['severity'] ?? '').toString().toLowerCase();
    return switch (_filter) {
      _SeverityFilter.high => s == 'high',
      _SeverityFilter.medium => s == 'medium',
      _SeverityFilter.low => s == 'low',
      _ => true,
    };
  }

  Future<void> _markResolved(String docId) async {
    try {
      await FirebaseFirestore.instance.collection('exception_logs').doc(docId).update({
        'resolved': true,
        'resolvedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.isAr ? 'تعذر التحديث' : 'Update failed'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isAr;
    final fmt = DateFormat.yMMMd(isAr ? 'ar' : 'en_US').add_Hm();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isAr ? 'مشاكل النظام' : 'System Issues',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.navy,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isAr ? 'سجل الأعطال من الخادم' : 'Server-reported exceptions',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('exception_logs')
                .orderBy('createdAt', descending: true)
                .limit(_limit)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      isAr ? 'تعذر تحميل السجل' : 'Could not load issues',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                  ),
                );
              }

              if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
                return const Card(
                  elevation: 0,
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                );
              }

              final docs = snap.data?.docs ?? [];
              var unresolved = 0;
              for (final d in docs) {
                final m = d.data();
                if (m['resolved'] != true) unresolved++;
              }

              final filtered = docs.where((d) => _passesFilter(d.data())).toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Chip(
                              avatar: Icon(
                                Icons.error_outline,
                                size: 18,
                                color: unresolved > 0 ? Colors.red.shade700 : Colors.grey.shade600,
                              ),
                              label: Text(
                                isAr
                                    ? 'غير محلولة: $unresolved'
                                    : 'Unresolved: $unresolved',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: unresolved > 0 ? Colors.red.shade800 : null,
                                ),
                              ),
                              backgroundColor: unresolved > 0
                                  ? Colors.red.shade50
                                  : Colors.grey.shade100,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<_SeverityFilter>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: _SeverityFilter.all,
                        label: Text(isAr ? 'الكل' : 'All'),
                      ),
                      ButtonSegment(
                        value: _SeverityFilter.high,
                        label: Text(isAr ? 'عالي' : 'High'),
                      ),
                      ButtonSegment(
                        value: _SeverityFilter.medium,
                        label: Text(isAr ? 'متوسط' : 'Med'),
                      ),
                      ButtonSegment(
                        value: _SeverityFilter.low,
                        label: Text(isAr ? 'منخفض' : 'Low'),
                      ),
                    ],
                    selected: {_filter},
                    onSelectionChanged: (next) {
                      if (next.isEmpty) return;
                      setState(() => _filter = next.first);
                    },
                  ),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          isAr ? 'لا توجد عناصر' : 'No issues in this view',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                      ),
                    )
                  else
                    ...filtered.map((doc) {
                      final m = doc.data();
                      final type = (m['type'] ?? '').toString();
                      final related = (m['relatedId'] ?? '').toString();
                      final message = (m['message'] ?? '').toString();
                      final severity = (m['severity'] ?? '').toString();
                      final resolved = m['resolved'] == true;
                      final createdAt = m['createdAt'];
                      final ts = createdAt is Timestamp ? createdAt.toDate() : null;
                      final timeLabel = ts == null ? '—' : fmt.format(ts);
                      final high = severity.toLowerCase() == 'high';

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: high ? Colors.red.shade400 : Colors.grey.shade200,
                              width: high ? 2 : 1,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _typeLabel(type),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: high
                                            ? Colors.red.shade50
                                            : Colors.orange.shade50,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: high
                                              ? Colors.red.shade200
                                              : Colors.orange.shade200,
                                        ),
                                      ),
                                      child: Text(
                                        _sevLabel(severity),
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                          color: high
                                              ? Colors.red.shade900
                                              : Colors.orange.shade900,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  timeLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (related.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  SelectableText(
                                    'id: $related',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade800,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Text(
                                  message,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.35,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Text(
                                      resolved
                                          ? (isAr ? 'محلولة' : 'Resolved')
                                          : (isAr ? 'مفتوحة' : 'Open'),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: resolved
                                            ? Colors.green.shade800
                                            : Colors.deepOrange.shade800,
                                      ),
                                    ),
                                    const Spacer(),
                                    if (!resolved)
                                      TextButton.icon(
                                        onPressed: () => _markResolved(doc.id),
                                        icon: const Icon(Icons.check_circle_outline, size: 20),
                                        label: Text(isAr ? 'تم الحل' : 'Resolve'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
