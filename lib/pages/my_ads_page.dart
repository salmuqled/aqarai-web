// lib/pages/my_ads_page.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// Firestore الموحد
import 'package:aqarai_app/services/firestore.dart';

// شاشة تسجيل الدخول
import 'package:aqarai_app/auth/login_page.dart';

// الترجمة
import 'package:aqarai_app/l10n/app_localizations.dart';

// صفحة التفاصيل
import 'package:aqarai_app/widgets/property_details_page.dart';
import 'package:aqarai_app/pages/wanted_details_page.dart';
import 'package:aqarai_app/pages/valuation_details_page.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';

enum AdsFilter { all, active, expired, featured, wanted, valuations }

class MyAdsPage extends StatefulWidget {
  const MyAdsPage({super.key});

  @override
  State<MyAdsPage> createState() => _MyAdsPageState();
}

class _MyAdsPageState extends State<MyAdsPage> {
  final _auth = FirebaseAuth.instance;

  final _fmtNum = NumberFormat.decimalPattern();
  AdsFilter _filter = AdsFilter.all;

  static const Color _primaryBlue = Color(0xFF101046);

  @override
  void initState() {
    super.initState();
    final u = _auth.currentUser;
    debugPrint("🔐 MyAdsPage Loaded — UID=${u?.uid}");
  }

  // تسجيل خروج
  Future<void> _logout() async {
    final loc = AppLocalizations.of(context)!;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(loc.logout),
        content: Text(loc.logoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _primaryBlue),
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.confirm),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _auth.signOut();
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(loc.logoutSuccess)));

      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  // Helpers
  String _fmtDate(Timestamp? ts) {
    final dt = ts?.toDate();
    if (dt == null) return '-';
    return DateFormat('yyyy/MM/dd – HH:mm').format(dt);
  }

  num? _parseNumFlexible(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    return num.tryParse(v.toString());
  }

  String _price(num? p) => p == null ? '-' : _fmtNum.format(p);

  String? _coverFrom(dynamic coverUrl, dynamic images) {
    String? pick(dynamic x) {
      final s = x?.toString().trim();
      if (s == null || s.isEmpty) return null;
      return s;
    }

    final c = pick(coverUrl);
    if (c != null) return c;

    if (images is List && images.isNotEmpty) return pick(images.first);
    if (images is Map && images.values.isNotEmpty) {
      return pick(images.values.first);
    }
    return null;
  }

  // طلبات المطلوب الخاصة بالمستخدم
  Query<Map<String, dynamic>> _wantedQuery(String uid) {
    return firestore
        .collection('wanted_requests')
        .where('ownerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true);
  }

  // طلبات التقييم العقاري الخاصة بالمستخدم
  Query<Map<String, dynamic>> _valuationsQuery(String uid) {
    return firestore
        .collection('valuations')
        .where('ownerId', isEqualTo: uid)
        .orderBy('createdAt', descending: true);
  }

  // الفلاتر
  Query<Map<String, dynamic>> _queryFor(String uid) {
    final now = Timestamp.now();

    final base = firestore
        .collection('properties')
        .where('ownerId', isEqualTo: uid);

    switch (_filter) {
      case AdsFilter.active:
        return base
            .where('status', isEqualTo: 'active')
            .orderBy('createdAt', descending: true);

      case AdsFilter.expired:
        return base
            .where('expiresAt', isLessThanOrEqualTo: now)
            .orderBy('expiresAt', descending: true);

      case AdsFilter.featured:
        return base
            .where('featuredUntil', isGreaterThanOrEqualTo: now)
            .orderBy('featuredUntil', descending: true);

      case AdsFilter.all:
      case AdsFilter.wanted:
      case AdsFilter.valuations:
        return base.orderBy('createdAt', descending: true);
    }
  }

  // ⭐ تمييز الإعلان — النسخة الصحيحة
  Future<void> _makeFeatured(String id) async {
    final now = DateTime.now();
    final end = now.add(const Duration(days: 7)); // 7 أيام تمييز

    try {
      await firestore.collection('properties').doc(id).update({
        'featuredUntil': Timestamp.fromDate(end),
        'approved': true,
        'status': 'active',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;

      final loc = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("✔ ${loc.adFeaturedSevenDays}"),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      final loc = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${loc.errorLabel}: $e"), backgroundColor: Colors.red),
      );
    }
  }

  /// تمييز طلب مطلوب ٧ أيام (لإظهاره في مطلوب مميز)
  Future<void> _makeWantedFeatured(String wantedId) async {
    final now = DateTime.now();
    final end = now.add(const Duration(days: 7));

    try {
      await firestore.collection('wanted_requests').doc(wantedId).update({
        'featuredUntil': Timestamp.fromDate(end),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      final isAr = Localizations.localeOf(context).languageCode == 'ar';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isAr ? 'تم تمييز الطلب لمدة ٧ أيام' : 'Wanted request featured for 7 days'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final loc = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${loc.errorLabel}: $e"), backgroundColor: Colors.red),
      );
    }
  }

  // حذف فعلي 🚀
  Future<void> _hardDelete(String id) async {
    final loc = AppLocalizations.of(context)!;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(loc.delete),
        content: Text(loc.hardDeleteWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _primaryBlue),
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.confirm),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await firestore.collection('properties').doc(id).delete();
    if (!mounted) return;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isAr ? 'تم الحذف' : 'Deleted'),
        backgroundColor: Colors.green,
      ),
    );
  }

  // حذف طلب مطلوب
  Future<void> _deleteWanted(String wantedId) async {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(loc.delete),
        content: Text(
          isAr ? 'هل تريد حذف هذا الطلب؟' : 'Delete this wanted request?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.delete),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await firestore.collection('wanted_requests').doc(wantedId).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isAr ? 'تم حذف الطلب' : 'Request deleted'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${loc.errorLabel}: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // حذف طلب التقييم العقاري
  Future<void> _deleteValuation(String valuationId) async {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(loc.delete),
        content: Text(
          isAr ? 'هل تريد حذف طلب التقييم؟' : 'Delete this valuation request?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.delete),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await firestore.collection('valuations').doc(valuationId).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isAr ? 'تم حذف الطلب' : 'Request deleted'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${loc.errorLabel}: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      Future.microtask(() {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.myAds),
        actions: [
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),

      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Wrap(
                spacing: 8,
                children: [
                  _filterChip(
                    loc.all,
                    _filter == AdsFilter.all,
                    () => setState(() => _filter = AdsFilter.all),
                  ),
                  _filterChip(
                    loc.active,
                    _filter == AdsFilter.active,
                    () => setState(() => _filter = AdsFilter.active),
                  ),
                  _filterChip(
                    loc.expiredAds,
                    _filter == AdsFilter.expired,
                    () => setState(() => _filter = AdsFilter.expired),
                  ),
                  _filterChip(
                    loc.featuredAds,
                    _filter == AdsFilter.featured,
                    () => setState(() => _filter = AdsFilter.featured),
                  ),
                  _filterChip(
                    loc.wanted,
                    _filter == AdsFilter.wanted,
                    () => setState(() => _filter = AdsFilter.wanted),
                  ),
                  _filterChip(
                    loc.valuation,
                    _filter == AdsFilter.valuations,
                    () => setState(() => _filter = AdsFilter.valuations),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),

          // عند اختيار «مطلوب»: نعرض فقط طلبات المطلوب
          if (_filter == AdsFilter.wanted) ...[
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _wantedQuery(user.uid).snapshots(),
              builder: (_, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(child: Text(loc.noWantedItems)),
                    ),
                  );
                }
                final isAr = locale == 'ar';
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _wantedCard(docs[i], loc, isAr),
                      ),
                      childCount: docs.length,
                    ),
                  ),
                );
              },
            ),
          ] else if (_filter == AdsFilter.valuations) ...[
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _valuationsQuery(user.uid).snapshots(),
              builder: (_, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(child: Text(loc.noWantedItems)),
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _valuationCard(docs[i], loc),
                      ),
                      childCount: docs.length,
                    ),
                  ),
                );
              },
            ),
          ] else ...[
            // إعلاناتي (عقارات): الكل / فعالة / منتهية / مميزة — الإعلان المنتهي يظهر في «منتهية»
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _queryFor(user.uid).snapshots(),
              builder: (_, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(child: Text(loc.noWantedItems)),
                    ),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _propertyCard(docs[i], loc, locale),
                      ),
                      childCount: docs.length,
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: _primaryBlue,
      labelStyle: TextStyle(color: selected ? Colors.white : Colors.black),
    );
  }

  Widget _propertyCard(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    AppLocalizations loc,
    String locale,
  ) {
    final d = doc.data();
    final id = doc.id;
    final typeEn = (d['type'] ?? '-').toString();
    final area = (d['area'] ?? '-').toString();
    final cover = _coverFrom(d['coverUrl'], d['images']);
    final createdAt = d['createdAt'] as Timestamp?;
    final expiresAt = d['expiresAt'] as Timestamp?;
    final price = _parseNumFlexible(d['price']);
    final featuredUntil = d['featuredUntil'] as Timestamp?;
    final isFeaturedNow = featuredUntil != null &&
        featuredUntil.toDate().isAfter(DateTime.now());

    late String typeLabel;
    if (locale == 'ar') {
      switch (typeEn.toLowerCase()) {
        case 'apartment': typeLabel = loc.propertyType_apartment; break;
        case 'house': typeLabel = loc.propertyType_house; break;
        case 'building': typeLabel = loc.propertyType_building; break;
        case 'land': typeLabel = loc.propertyType_land; break;
        case 'industrialland': typeLabel = loc.propertyType_industrialLand; break;
        case 'shop': typeLabel = loc.propertyType_shop; break;
        case 'office': typeLabel = loc.propertyType_office; break;
        case 'chalet': typeLabel = loc.propertyType_chalet; break;
        default: typeLabel = typeEn;
      }
    } else {
      typeLabel = typeEn;
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => PropertyDetailsPage(propertyId: id),
          ),
        );
      },
      child: Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CoverThumb(url: cover),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "$area • $typeLabel",
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "${loc.price}: ${_price(price)} KWD",
                      style: const TextStyle(
                        fontSize: 15,
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "${loc.addedOn}: ${_fmtDate(createdAt)}\n"
                      "${loc.expiresOn}: ${_fmtDate(expiresAt)}",
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: _Actions(
                  loc: loc,
                  featured: isFeaturedNow,
                  onFeature: () => _makeFeatured(id),
                  onDelete: () => _hardDelete(id),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _wantedCard(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    AppLocalizations loc,
    bool isAr,
  ) {
    final d = doc.data();
    final wantedId = doc.id;
    final govRaw = (d['governorate'] ?? '').toString();
    final areaRaw = (d['area'] ?? '').toString();
    final gov = isAr ? govRaw : (governorateArToEn[govRaw] ?? govRaw);
    final area = isAr ? areaRaw : (areaArToEn[areaRaw] ?? areaRaw);
    final type = (d['propertyType'] ?? d['type'] ?? '').toString();
    final min = d['minPrice'];
    final max = d['maxPrice'];
    final createdAt = d['createdAt'] as Timestamp?;
    final approved = d['approved'] == true;
    final featuredUntil = d['featuredUntil'] as Timestamp?;
    final isFeaturedNow = featuredUntil != null &&
        featuredUntil.toDate().isAfter(DateTime.now());

    String typeLabel;
    switch (type) {
      case 'apartment': typeLabel = loc.propertyType_apartment; break;
      case 'house': typeLabel = loc.propertyType_house; break;
      case 'building': typeLabel = loc.propertyType_building; break;
      case 'land': typeLabel = loc.propertyType_land; break;
      case 'industrialLand': typeLabel = loc.propertyType_industrialLand; break;
      case 'shop': typeLabel = loc.propertyType_shop; break;
      case 'office': typeLabel = loc.propertyType_office; break;
      case 'chalet': typeLabel = loc.propertyType_chalet; break;
      default: typeLabel = type;
    }

    return GestureDetector(
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
      child: Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 72,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[200],
                ),
                child: const Icon(
                  Icons.search,
                  color: Colors.black45,
                  size: 28,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "$gov • $area",
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "${loc.propertyType}: $typeLabel",
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "${loc.budget}: ${min ?? '-'} → ${max ?? '-'} ${isAr ? 'د.ك' : 'KWD'}",
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "${loc.addedOn}: ${_fmtDate(createdAt)}",
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    if (approved)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle,
                                color: Colors.green[700], size: 16),
                            const SizedBox(width: 4),
                            Text(
                              isAr ? 'معتمد' : 'Approved',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.green[700],
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (approved)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: TextButton.icon(
                          onPressed: () => _makeWantedFeatured(wantedId),
                          icon: Icon(
                            isFeaturedNow ? Icons.star : Icons.star_border,
                            size: 18,
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.amber[800],
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          label: Text(
                            isFeaturedNow ? loc.extendFeature : loc.makeFeatured,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (approved && isFeaturedNow)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.amber[100],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star, size: 14, color: Colors.amber[800]),
                              const SizedBox(width: 4),
                              Text(
                                isAr ? 'مميز' : 'Featured',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.amber[900],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => _deleteWanted(wantedId),
                      icon: const Icon(Icons.delete_outline, size: 20),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      label: Text(
                        loc.delete,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _valuationCard(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    AppLocalizations loc,
  ) {
    final d = doc.data();
    final valuationId = doc.id;
    final owner = (d['ownerName'] ?? '-').toString();
    final gov = (d['governorate'] ?? '-').toString();
    final area = (d['area'] ?? '-').toString();
    final pType = (d['propertyType'] ?? '-').toString();
    final pArea = (d['propertyArea'] ?? '-').toString();
    final createdAt = d['createdAt'] as Timestamp?;

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ValuationDetailsPage(valuationId: valuationId),
          ),
        );
      },
      child: Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 72,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[200],
                ),
                child: const Icon(
                  Icons.assessment,
                  color: Colors.black45,
                  size: 28,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$owner • $gov - $area',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${loc.valuation_propertyType}: $pType | ${loc.valuation_propertyArea}: $pArea',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${loc.addedOn}: ${_fmtDate(createdAt)}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: TextButton.icon(
                  onPressed: () => _deleteValuation(valuationId),
                  icon: const Icon(Icons.delete_outline, size: 20),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  label: Text(
                    loc.delete,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  final AppLocalizations loc;
  final bool featured;
  final VoidCallback onFeature;
  final VoidCallback onDelete;

  const _Actions({
    required this.loc,
    required this.featured,
    required this.onFeature,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: onFeature,
          icon: const Icon(Icons.star),
          style: TextButton.styleFrom(foregroundColor: Colors.blue),
          label: Text(featured ? loc.extendFeature : loc.makeFeatured),
        ),
        TextButton.icon(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          label: Text(loc.delete),
        ),
      ],
    );
  }
}

class _CoverThumb extends StatelessWidget {
  final String? url;

  const _CoverThumb({this.url});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey[200],
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
