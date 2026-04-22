// lib/pages/admin/tabs/admin_pending_tab.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:aqarai_app/utils/listing_display.dart';

class AdminPendingTab extends StatefulWidget {
  const AdminPendingTab({super.key});

  @override
  State<AdminPendingTab> createState() => _AdminPendingTabState();
}

class _AdminPendingTabState extends State<AdminPendingTab> {
  late bool isArabic;

  // ✅ FIX: Firestore instance (كان مفقود ويسبب error)
  final FirebaseFirestore firestore = FirebaseFirestore.instance;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    isArabic = Localizations.localeOf(context).languageCode == 'ar';
  }

  Query<Map<String, dynamic>> _query() {
    return firestore
        .collection('properties')
        .where('approved', isEqualTo: false)
        .orderBy('createdAt', descending: true);
  }

  Future<void> _approve(String propertyId) async {
    try {
      final funcs = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = funcs.httpsCallable('approveListing');
      final res = await callable.call({'propertyId': propertyId});
      final ok = (res.data is Map) ? (res.data['ok'] == true) : true;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (isArabic ? 'تم اعتماد الإعلان' : 'Listing approved')
                : (isArabic ? 'تعذّر الاعتماد' : 'Approval failed'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isArabic ? 'خطأ: $e' : 'Error: $e')),
      );
    }
  }

  Future<void> _reject(String propertyId) async {
    String reason = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isArabic ? 'رفض الإعلان' : 'Reject listing'),
        content: TextField(
          decoration: InputDecoration(
            hintText: isArabic
                ? 'اذكر سبب الرفض (اختياري)'
                : 'Reason (optional)',
          ),
          maxLines: 3,
          onChanged: (v) => reason = v,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(isArabic ? 'رفض' : 'Reject'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final funcs = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = funcs.httpsCallable('rejectListing');
      final res = await callable.call({
        'propertyId': propertyId,
        'reason': reason,
      });

      final ok = (res.data is Map) ? (res.data['ok'] == true) : true;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (isArabic ? 'تم رفض الإعلان' : 'Listing rejected')
                : (isArabic ? 'تعذّر الرفض' : 'Reject failed'),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isArabic ? 'خطأ: $e' : 'Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _query().snapshots(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }

        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Center(
            child: Text(
              isArabic ? 'لا توجد إعلانات قيد المراجعة' : 'No pending listings',
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            final id = docs[i].id;
            final d = docs[i].data();

            final title = (d['title'] ?? '').toString();
            final type = (d['type'] ?? '-').toString();
            final area = (d['area'] ?? d['area_id'] ?? '-').toString();
            final price = d['price'];
            final cover = (d['coverUrl'] ?? (d['images']?['0']))?.toString();
            // Owner-provided chalet name takes priority over the legacy
            // `title` field and the synthesized "type • area" fallback so
            // admins see the exact name they'll approve.
            final chaletName = listingChaletName(d);
            final displayTitle = chaletName.isNotEmpty
                ? chaletName
                : (title.isNotEmpty ? title : '$area • $type');
            final subtitleLine = chaletName.isNotEmpty
                ? '$area • $type'
                : null;

            return Card(
              elevation: 1,
              child: ListTile(
                leading: _Thumb(url: cover),
                title: Text(
                  displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (subtitleLine != null)
                      Text(
                        subtitleLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    Text(
                      price == null
                          ? (isArabic ? 'بدون سعر' : 'No price')
                          : ((isArabic ? 'السعر: ' : 'Price: ') +
                              price.toString()),
                    ),
                  ],
                ),
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () => _approve(id),
                      icon: const Icon(Icons.verified),
                      label: Text(isArabic ? 'اعتماد' : 'Approve'),
                    ),
                    TextButton.icon(
                      onPressed: () => _reject(id),
                      icon: const Icon(Icons.block),
                      label: Text(isArabic ? 'رفض' : 'Reject'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  final String? url;
  const _Thumb({this.url});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      width: 72,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
        image: (url != null && url!.isNotEmpty)
            ? DecorationImage(image: NetworkImage(url!), fit: BoxFit.cover)
            : null,
      ),
      child: (url == null || url!.isEmpty)
          ? const Icon(Icons.home, color: Colors.black45)
          : null,
    );
  }
}
