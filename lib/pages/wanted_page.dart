// lib/pages/wanted_page.dart

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/pages/add_wanted_page.dart';
import 'package:aqarai_app/pages/wanted_details_page.dart';
import 'package:aqarai_app/widgets/featured_wanted_carousel.dart';

class WantedPage extends StatefulWidget {
  const WantedPage({super.key});

  @override
  State<WantedPage> createState() => _WantedPageState();
}

class _WantedPageState extends State<WantedPage> {
  final int _pageSize = 20;

  List<DocumentSnapshot> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _noMore = false;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    if (_loading) return;
    setState(() => _loading = true);

    final snap = await FirebaseFirestore.instance
        .collection('wanted_requests')
        .where('approved', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .limit(_pageSize)
        .get();

    setState(() {
      _items = snap.docs;
      _loading = false;
      _noMore = snap.docs.length < _pageSize;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _noMore) return;

    setState(() => _loadingMore = true);

    final last = _items.last;

    final snap = await FirebaseFirestore.instance
        .collection('wanted_requests')
        .where('approved', isEqualTo: true)
        .orderBy('createdAt', descending: true)
        .startAfterDocument(last)
        .limit(_pageSize)
        .get();

    setState(() {
      _items.addAll(snap.docs);
      _loadingMore = false;
      if (snap.docs.length < _pageSize) _noMore = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Scaffold(
      appBar: AppBar(title: Text(loc.wanted), centerTitle: true),

      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200 &&
                    !_loadingMore) {
                  _loadMore();
                }
                return false;
              },
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: 1 +
                    (_items.isEmpty ? 1 : _items.length) +
                    (_loadingMore ? 1 : 0),
                itemBuilder: (context, i) {
                  // أول عنصر: قسم مطلوب مميز
                  if (i == 0) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const FeaturedWantedCarousel(darkBackground: false),
                        const SizedBox(height: 24),
                      ],
                    );
                  }
                  // بعد المميز: لا توجد طلبات أخرى
                  if (_items.isEmpty) {
                    return _EmptyState(loc: loc);
                  }
                  // مؤشر تحميل المزيد
                  if (i > _items.length) {
                    return const Padding(
                      padding: EdgeInsets.all(12.0),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }

                  final doc = _items[i - 1];
                  final data = doc.data() as Map<String, dynamic>? ?? {};

                  return _WantedUnifiedCard(
                    data: data,
                    wantedId: doc.id,
                    isAr: isAr,
                    loc: loc,
                  );
                },
              ),
            ),

      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AddWantedPage()),
          );
        },
        icon: const Icon(Icons.add),
        label: Text(loc.postWanted),
      ),
    );
  }
}

// ------------------------------------------------------------
// كارد موحد — نفس كارد العقارات
// ------------------------------------------------------------
class _WantedUnifiedCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String wantedId;
  final bool isAr;
  final AppLocalizations loc;

  const _WantedUnifiedCard({
    required this.data,
    required this.wantedId,
    required this.isAr,
    required this.loc,
  });

  @override
  Widget build(BuildContext context) {
    final govRaw = (data['governorate'] ?? '').toString();
    final areaRaw = (data['area'] ?? '').toString();
    final gov = isAr ? govRaw : (governorateArToEn[govRaw] ?? govRaw);
    final area = isAr ? areaRaw : (areaArToEn[areaRaw] ?? areaRaw);
    final type = data['propertyType'] ?? '';
    final desc = data['description'] ?? '';
    final min = data['minPrice'];
    final max = data['maxPrice'];
    final createdAt = data['createdAt'] as Timestamp?;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),

        // لا يوجد صور → نستخدم Icon بنفس حجم كارد العقار
        leading: Container(
          width: 72,
          height: 52,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.receipt_long,
            color: Colors.black45,
            size: 30,
          ),
        ),

        title: Text(
          "$gov • $area",
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),

        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),

            // نوع العقار
            Text("${loc.propertyType}: ${_mapType(type)}"),

            const SizedBox(height: 4),

            // السعر
            if (min != null || max != null)
              Text(
                isAr
                    ? "السعر: ${min ?? '-'} → ${max ?? '-'} د.ك"
                    : "Price: ${min ?? '-'} → ${max ?? '-'} KWD",
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),

            const SizedBox(height: 4),

            // الوصف
            Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis),

            const SizedBox(height: 6),

            // تاريخ الإضافة
            Text(
              _formatDate(createdAt),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),

        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => WantedDetailsPage(
                wantedId: wantedId,
                isAdminView: false,
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatDate(Timestamp? ts) {
    if (ts == null) return "-";
    final dt = ts.toDate();
    return "${dt.year}/${dt.month}/${dt.day}";
  }

  String _mapType(String key) {
    switch (key) {
      case 'apartment':
        return loc.propertyType_apartment;
      case 'house':
        return loc.propertyType_house;
      case 'building':
        return loc.propertyType_building;
      case 'land':
        return loc.propertyType_land;
      case 'industrialLand':
        return loc.propertyType_industrialLand;
      case 'shop':
        return loc.propertyType_shop;
      case 'office':
        return loc.propertyType_office;
      case 'chalet':
        return loc.propertyType_chalet;
      default:
        return key;
    }
  }
}

// ------------------------------------------------------------
// EMPTY STATE
// ------------------------------------------------------------
class _EmptyState extends StatelessWidget {
  final AppLocalizations loc;

  const _EmptyState({required this.loc});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hourglass_empty, size: 70),
            const SizedBox(height: 16),
            Text(loc.noWantedItems, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              loc.wantedList,
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
