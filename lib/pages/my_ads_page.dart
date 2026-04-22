// lib/pages/my_ads_page.dart

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:image_picker/image_picker.dart';
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
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/property_closure_service.dart';
import 'package:aqarai_app/utils/property_listing_cover.dart';
import 'package:aqarai_app/utils/property_price_display.dart';
import 'package:aqarai_app/widgets/listing_thumbnail_image.dart';
import 'package:aqarai_app/services/image_processing_service.dart';
import 'package:aqarai_app/services/property_listing_image_service.dart';
import 'package:aqarai_app/services/featured_property_service.dart';
import 'package:aqarai_app/services/payment/payment_service_provider.dart';
import 'package:aqarai_app/utils/listing_display.dart';
import 'package:aqarai_app/pages/owner_chalet_finance_page.dart';
import 'package:aqarai_app/pages/owner_dashboard_page.dart';

/// Unified row for My Ads → «All» tab (properties + wanted + valuations).
class _AllTabItem {
  const _AllTabItem({
    required this.itemType,
    required this.doc,
    required this.sortAt,
    required this.title,
  });

  /// `property` | `wanted` | `valuation`
  final String itemType;
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final Timestamp sortAt;
  final String title;
}

Timestamp _safeCreatedAt(Map<String, dynamic> d) {
  final t = d['createdAt'];
  if (t is Timestamp) return t;
  return Timestamp.fromMillisecondsSinceEpoch(0);
}

String _allTabTitleForProperty(Map<String, dynamic> d) {
  final area = (d['area'] ?? d['areaAr'] ?? '').toString().trim();
  final ty = (d['type'] ?? '').toString().trim();
  if (area.isEmpty && ty.isEmpty) return '-';
  if (area.isEmpty) return ty;
  if (ty.isEmpty) return area;
  return '$area • $ty';
}

String _allTabTitleForWanted(Map<String, dynamic> d) {
  final g = (d['governorate'] ?? '').toString().trim();
  final a = (d['area'] ?? '').toString().trim();
  if (g.isEmpty && a.isEmpty) return '-';
  if (g.isEmpty) return a;
  if (a.isEmpty) return g;
  return '$g • $a';
}

String _allTabTitleForValuation(Map<String, dynamic> d) {
  final o = (d['ownerName'] ?? '').toString().trim();
  final a = (d['area'] ?? '').toString().trim();
  if (o.isEmpty && a.isEmpty) return '-';
  if (o.isEmpty) return a;
  if (a.isEmpty) return o;
  return '$o • $a';
}

List<_AllTabItem> _mergeAllTabSnapshots(
  QuerySnapshot<Map<String, dynamic>> properties,
  QuerySnapshot<Map<String, dynamic>> wanted,
  QuerySnapshot<Map<String, dynamic>> valuations,
) {
  final out = <_AllTabItem>[];

  for (final doc in properties.docs) {
    final d = doc.data();
    out.add(
      _AllTabItem(
        itemType: 'property',
        doc: doc,
        sortAt: _safeCreatedAt(d),
        title: _allTabTitleForProperty(d),
      ),
    );
  }
  for (final doc in wanted.docs) {
    final d = doc.data();
    out.add(
      _AllTabItem(
        itemType: 'wanted',
        doc: doc,
        sortAt: _safeCreatedAt(d),
        title: _allTabTitleForWanted(d),
      ),
    );
  }
  for (final doc in valuations.docs) {
    final d = doc.data();
    out.add(
      _AllTabItem(
        itemType: 'valuation',
        doc: doc,
        sortAt: _safeCreatedAt(d),
        title: _allTabTitleForValuation(d),
      ),
    );
  }

  int ms(Timestamp t) => t.millisecondsSinceEpoch;
  out.sort((a, b) => ms(b.sortAt).compareTo(ms(a.sortAt)));
  return out;
}

/// Single stream: latest merged list whenever any of the three collections changes.
Stream<List<_AllTabItem>> _mergedAllAdsStream(String uid) {
  return Stream<List<_AllTabItem>>.multi((controller) {
    QuerySnapshot<Map<String, dynamic>>? pSnap;
    QuerySnapshot<Map<String, dynamic>>? wSnap;
    QuerySnapshot<Map<String, dynamic>>? vSnap;

    final subs = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];

    void emit() {
      if (pSnap == null || wSnap == null || vSnap == null) return;
      try {
        controller.add(_mergeAllTabSnapshots(pSnap!, wSnap!, vSnap!));
      } catch (e, st) {
        controller.addError(e, st);
      }
    }

    subs.add(
      firestore
          .collection('properties')
          .where('ownerId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .listen(
            (s) {
              pSnap = s;
              emit();
            },
            onError: controller.addError,
          ),
    );
    subs.add(
      firestore
          .collection('wanted_requests')
          .where('ownerId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .listen(
            (s) {
              wSnap = s;
              emit();
            },
            onError: controller.addError,
          ),
    );
    subs.add(
      firestore
          .collection('valuations')
          .where('ownerId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .listen(
            (s) {
              vSnap = s;
              emit();
            },
            onError: controller.addError,
          ),
    );

    controller.onCancel = () {
      for (final s in subs) {
        s.cancel();
      }
    };
  }, isBroadcast: true);
}

enum AdsFilter { all, active, expired, featured, wanted, valuations }

String _myAdsClosedDealChipFromServiceType(
  Map<String, dynamic> d,
  String languageCode,
) {
  final st = (d['serviceType'] ?? 'sale').toString().toLowerCase().trim();
  if (languageCode == 'ar') {
    switch (st) {
      case 'rent':
        return 'تم التأجير';
      case 'exchange':
        return 'تمت الصفقة';
      case 'sale':
      default:
        return 'تم البيع';
    }
  }
  switch (st) {
    case 'rent':
      return 'Rented';
    case 'exchange':
      return 'Exchanged';
    case 'sale':
    default:
      return 'Sold';
  }
}

/// My Ads: Arabic/English "sold" (and peer terminal labels) only when
/// `properties.dealStatus == DealStatus.closed` — never from `status` alone.
String _myAdsPropertyStatusChipLabel(Map<String, dynamic> d, String languageCode) {
  final dealStatus = (d['dealStatus'] ?? '').toString().trim();
  final listingStatus = (d['status'] ?? ListingStatus.active).toString().trim();

  if (dealStatus == DealStatus.closed) {
    return _myAdsClosedDealChipFromServiceType(d, languageCode);
  }

  if (listingStatus == ListingStatus.sold ||
      listingStatus == ListingStatus.rented ||
      listingStatus == ListingStatus.exchanged) {
    final patched = Map<String, dynamic>.from(d);
    patched['status'] = ListingStatus.active;
    return listingStatusChipLabel(patched, languageCode);
  }

  return listingStatusChipLabel(d, languageCode);
}

/// True when the property card should show the rich «under review» owner UX (My Ads only).
bool _myAdsPropertyIsPendingReviewUi(Map<String, dynamic> d) {
  if (listingDataNeedsImageUpload(d)) return false;
  final st = (d['status'] ?? ListingStatus.active).toString().trim();
  switch (st) {
    case ListingStatus.pendingApproval:
    case ListingStatus.pendingSaleConfirmation:
    case ListingStatus.pendingRentConfirmation:
    case ListingStatus.pendingExchangeConfirmation:
      return true;
    default:
      break;
  }
  if (d['approved'] != true && !listingDataIsClosedDeal(d)) {
    return true;
  }
  return false;
}

/// Simplified My Ads status line: Active vs Sold (UI only; does not change Firestore).
String _myAdsPropertyCardSimpleStatusLabel(
  Map<String, dynamic> d,
  String locale,
) {
  final isAr = locale == 'ar';
  final st = (d['status'] ?? ListingStatus.active).toString().trim();
  if (listingDataIsClosedDeal(d) || st == ListingStatus.sold) {
    return isAr ? 'تم البيع' : 'Sold';
  }
  return isAr ? 'نشط' : 'Active';
}

Widget _myAdsPendingReviewStatusBlock({required bool isAr}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.end,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _MyAdsPendingPulseDot(),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Text(
              isAr ? '🟠 قيد المراجعة' : '🟠 Under Review',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.orange.shade900,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Text(
          isAr
              ? 'عقارك قيد المراجعة حالياً، وغالباً يتم اعتماده خلال دقائق'
              : 'Your property is being reviewed. This usually takes a few minutes.',
          style: TextStyle(
            fontSize: 12,
            height: 1.35,
            color: Colors.grey[700],
          ),
          textAlign: TextAlign.end,
        ),
      ),
    ],
  );
}

/// Small pulsing dot for pending-review badge (subtle, non-interactive).
class _MyAdsPendingPulseDot extends StatefulWidget {
  const _MyAdsPendingPulseDot();

  @override
  State<_MyAdsPendingPulseDot> createState() => _MyAdsPendingPulseDotState();
}

class _MyAdsPendingPulseDotState extends State<_MyAdsPendingPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.38, end: 0.82).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: Colors.orange.shade700,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Small type chip for My Ads → «All» merged list (`property` | `wanted` | `valuation`).
Widget buildTypeLabel(String type, {String locale = 'ar'}) {
  final t = type.trim().toLowerCase();
  if (t.isEmpty) return const SizedBox.shrink();

  late final String labelText;
  late final String icon;
  late final Color bg;
  late final Color fg;

  switch (t) {
    case 'property':
      icon = '🏠';
      labelText = locale == 'ar' ? 'عقار' : 'Property';
      bg = const Color(0xFFE3F2FD);
      fg = const Color(0xFF1565C0);
      break;
    case 'wanted':
      icon = '🔍';
      labelText = locale == 'ar' ? 'مطلوب' : 'Wanted';
      bg = const Color(0xFFFFF3E0);
      fg = const Color(0xFFEF6C00);
      break;
    case 'valuation':
      icon = '📊';
      labelText = locale == 'ar' ? 'تقييم' : 'Valuation';
      bg = const Color(0xFFF3E5F5);
      fg = const Color(0xFF6A1B9A);
      break;
    default:
      return const SizedBox.shrink();
  }

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          icon,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          labelText,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}

class MyAdsPage extends StatefulWidget {
  const MyAdsPage({super.key});

  @override
  State<MyAdsPage> createState() => _MyAdsPageState();
}

class _MyAdsPageState extends State<MyAdsPage> {
  final _auth = FirebaseAuth.instance;

  final _fmtNum = NumberFormat.decimalPattern();
  AdsFilter _filter = AdsFilter.all;

  /// Cached merged stream for «All» tab (broadcast; one instance per owner uid).
  String? _mergedAllStreamUid;
  Stream<List<_AllTabItem>>? _mergedAllStream;

  Stream<List<_AllTabItem>> _mergedAllAdsStreamFor(String uid) {
    if (_mergedAllStream != null && _mergedAllStreamUid == uid) {
      return _mergedAllStream!;
    }
    _mergedAllStreamUid = uid;
    _mergedAllStream = _mergedAllAdsStream(uid);
    return _mergedAllStream!;
  }

  /// While non-null, main-photo retry is running for this property id.
  String? _propertyImageRetryBusyId;

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

  Future<void> _confirmClosureAndSubmit(String propertyId, String serviceType) async {
    if (!mounted) return;
    final rt = closeRequestTypeForServiceType(serviceType);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مبروك'),
        content: const Text(
          'ألف مبروك، سعداء بهذا الخبر. بتأكيدك سيتم إنهاء الإعلان مؤقتاً وإرسال طلب مراجعة للإدارة لاعتماد الحالة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    try {
      await PropertyClosureService().submitClosureRequest(
        propertyId: propertyId,
        requestType: rt,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم إرسال الطلب — إعلانك بانتظار اعتماد الإدارة'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر الإرسال: $e'), backgroundColor: Colors.red),
      );
    }
  }

  /// عرض للبيع / للإيجار / البدل على بطاقة إعلاناتي
  String _propertyServiceLabel(String? raw, AppLocalizations loc) {
    switch ((raw ?? 'sale').toString().toLowerCase().trim()) {
      case 'rent':
        return loc.forRent;
      case 'exchange':
        return loc.forExchange;
      case 'sale':
      default:
        return loc.forSale;
    }
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
        // Live marketplace slice: filter with [listingDataIsPubliclyDiscoverable] in UI (no status).
        return base.orderBy('createdAt', descending: true);

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
  Future<void> _retryPropertyMainImageUpload(String propertyId) async {
    if (_propertyImageRetryBusyId != null) return;
    setState(() => _propertyImageRetryBusyId = propertyId);

    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      final raw = File(picked.path);
      if (!await raw.exists() || await raw.length() <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isAr ? 'ملف الصورة غير صالح' : 'Invalid image file'),
            ),
          );
        }
        return;
      }

      File file;
      try {
        file = await ImageProcessingService.processImage(raw);
      } catch (e, st) {
        debugPrint('[MyAds] Image process failed: $e\n$st');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isAr
                    ? 'تعذر معالجة الصورة. حاول صورة أخرى.'
                    : 'Could not process the image. Try another photo.',
              ),
            ),
          );
        }
        return;
      }

      final up = await PropertyListingImageService.uploadMainPhotoToStorage(
        propertyId: propertyId,
        file: file,
        isUserRetry: true,
      );
      try {
        await PropertyListingImageService.applyUploadedImageToProperty(
          propertyId: propertyId,
          downloadUrl: up.fullUrl,
          thumbnailUrl: up.thumbUrl,
          setDocumentIdField: false,
        );
      } catch (_) {
        try {
          await up.fullRef.delete();
        } catch (_) {}
        try {
          await up.thumbRef.delete();
        } catch (_) {}
        rethrow;
      }

      await ImageProcessingService.tryDeleteTemp(file);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr ? 'تم رفع الصورة بنجاح' : 'Photo uploaded successfully',
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${loc.errorLabel}: ${e.code} ${e.message ?? ""}',
          ),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${loc.errorLabel}: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _propertyImageRetryBusyId = null);
      }
    }
  }

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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
      });
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_mergedAllStreamUid != null && _mergedAllStreamUid != user.uid) {
      _mergedAllStream = null;
      _mergedAllStreamUid = null;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.myAds),
        actions: [
          IconButton(
            tooltip: loc.ownerDashboardTitle,
            icon: const Icon(Icons.insights_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const OwnerDashboardPage(),
                ),
              );
            },
          ),
          IconButton(
            tooltip: loc.ownerChaletFinanceTitle,
            icon: const Icon(Icons.account_balance_wallet_outlined),
            onPressed: () {
              Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const OwnerChaletFinancePage(),
                ),
              );
            },
          ),
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
                        child: _valuationCard(docs[i], loc, locale),
                      ),
                      childCount: docs.length,
                    ),
                  ),
                );
              },
            ),
          ] else if (_filter == AdsFilter.all) ...[
            StreamBuilder<List<_AllTabItem>>(
              stream: _mergedAllAdsStreamFor(user.uid),
              builder: (_, snap) {
                if (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData) {
                  return const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                if (snap.hasError) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          '${loc.errorLabel}: ${snap.error}',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  );
                }
                final items = snap.data ?? [];
                if (items.isEmpty) {
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
                      (context, i) {
                        final e = items[i];
                        final child = switch (e.itemType) {
                          'property' => _propertyCard(
                              e.doc,
                              loc,
                              locale,
                              listItemType: 'property',
                            ),
                          'wanted' => _wantedCard(
                              e.doc,
                              loc,
                              isAr,
                              listItemType: 'wanted',
                            ),
                          'valuation' => _valuationCard(
                              e.doc,
                              loc,
                              locale,
                              listItemType: 'valuation',
                            ),
                          _ => const SizedBox.shrink(),
                        };
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: child,
                        );
                      },
                      childCount: items.length,
                    ),
                  ),
                );
              },
            ),
          ] else ...[
            // إعلاناتي (عقارات): فعالة / منتهية / مميزة — الإعلان المنتهي يظهر في «منتهية»
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
                var docs = snap.data?.docs ?? [];
                if (_filter == AdsFilter.active) {
                  docs = docs
                      .where(
                        (doc) => listingDataIsPubliclyDiscoverable(doc.data()),
                      )
                      .toList();
                }
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
    String locale, {
    String? listItemType,
  }) {
    final d = doc.data();
    final id = doc.id;
    final typeEn = (d['type'] ?? '-').toString();
    final area = (d['area'] ?? '-').toString();
    final cover = PropertyListingCover.urlFrom(d);
    final createdAt = d['createdAt'] as Timestamp?;
    final expiresAt = d['expiresAt'] as Timestamp?;
    final price = _parseNumFlexible(d['price']);
    final featuredUntil = d['featuredUntil'] as Timestamp?;
    final isFeaturedNow = featuredUntil != null &&
        featuredUntil.toDate().isAfter(DateTime.now());
    final featuredDaysLeft = (() {
      if (!isFeaturedNow) return null;
      final end = featuredUntil.toDate();
      final diff = end.difference(DateTime.now());
      if (diff.isNegative) return 0;
      // Round up so "0.2 days left" shows as 1.
      return (diff.inHours / 24).ceil().clamp(0, 3650);
    })();
    final featuredUrgent = featuredDaysLeft != null && featuredDaysLeft <= 2;
    final serviceLabel = _propertyServiceLabel(d['serviceType']?.toString(), loc);
    final approved = d['approved'] == true;
    final needsPhoto = listingDataNeedsImageUpload(d);
    final isAr = locale == 'ar';
    final displayType = resolveDisplayPriceType(
      serviceType: d['serviceType']?.toString(),
      priceType: d['priceType']?.toString(),
    );
    final priceUnit = priceSuffix(displayType, isAr);
    final statusChip = _myAdsPropertyStatusChipLabel(d, locale);
    if (kDebugMode) {
      final st = (d['status'] ?? ListingStatus.active).toString().trim();
      final dealStatus = (d['dealStatus'] ?? '').toString().trim();
      final hasImage = d['hasImage'];
      final imgs = d['images'];
      final thumbs = d['thumbnails'];
      final imagesLen = imgs is List ? imgs.length : 0;
      final thumbsLen = thumbs is List ? thumbs.length : 0;
      debugPrint(
        '[MyAds] status-chip propertyId=$id status=$st dealStatus=$dealStatus '
        'approved=$approved hasImage=$hasImage imagesLen=$imagesLen '
        'thumbsLen=$thumbsLen needsPhoto=$needsPhoto finalLabel=$statusChip',
      );
    }
    final canFeature = approved &&
        !listingDataIsClosedDeal(d) &&
        d['closeRequestSubmitted'] != true &&
        listingDataIsPubliclyDiscoverable(d);
    final listingSt =
        (d['status'] ?? ListingStatus.active).toString().trim();
    final showClosureBtn = approved &&
        listingDataCanSubmitClosure(d) &&
        !_myAdsPropertyIsPendingReviewUi(d) &&
        (listingSt == ListingStatus.active ||
            listingSt == ListingStatus.approvedLegacy);

    final chaletName = listingChaletName(d);

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
            builder: (_) => PropertyDetailsPage(
              propertyId: id,
              leadSource: DealLeadSource.direct,
            ),
          ),
        );
      },
      child: Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
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
                        // Owner-provided chalet name wins when present — it
                        // becomes the bold title and the classic "area • type"
                        // line moves to a secondary subtitle. Listings without
                        // a custom name render exactly as before.
                        if (chaletName.isNotEmpty) ...[
                          Text(
                            chaletName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "$area • $typeLabel",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey[600],
                            ),
                          ),
                        ] else
                          Text(
                            "$area • $typeLabel",
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          "${loc.price}: ${_price(price)} KWD$priceUnit",
                          style: const TextStyle(
                            fontSize: 15,
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "${loc.serviceTypeLabel}: $serviceLabel",
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _primaryBlue,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: listingDataNeedsImageUpload(d)
                              ? Chip(
                                  label: Text(
                                    statusChip,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                )
                              : _myAdsPropertyIsPendingReviewUi(d)
                                  ? _myAdsPendingReviewStatusBlock(isAr: isAr)
                                  : Chip(
                                      label: Text(
                                        _myAdsPropertyCardSimpleStatusLabel(
                                          d,
                                          locale,
                                        ),
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                    ),
                        ),
                        if (needsPhoto) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.orange.shade300),
                                  ),
                                  child: Text(
                                    isAr
                                        ? 'مطلوب رفع صورة لإرسال الطلب للاعتماد'
                                        : 'Upload a photo before admin can approve',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.orange.shade900,
                                    ),
                                    textAlign: TextAlign.end,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                FilledButton.tonalIcon(
                                  onPressed: _propertyImageRetryBusyId == id
                                      ? null
                                      : () => _retryPropertyMainImageUpload(id),
                                  icon: _propertyImageRetryBusyId == id
                                      ? SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.blue.shade800,
                                          ),
                                        )
                                      : const Icon(Icons.cloud_upload_outlined, size: 20),
                                  label: Text(isAr ? 'إعادة رفع الصورة' : 'Retry upload'),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (showClosureBtn) ...[
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.tonal(
                              onPressed: () => _confirmClosureAndSubmit(
                                id,
                                d['serviceType']?.toString() ?? 'sale',
                              ),
                              child: Text(
                                closureButtonLabelAr(d['serviceType']?.toString() ?? 'sale'),
                              ),
                            ),
                          ),
                        ],
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
                      propertyId: id,
                      featured: isFeaturedNow,
                      featuredDaysLeft: featuredDaysLeft,
                      featuredUrgent: featuredUrgent,
                      canFeature: canFeature,
                      onDelete: () => _hardDelete(id),
                    ),
                  ),
                ],
              ),
            ),
            if (listItemType case final String tag when tag.isNotEmpty)
              PositionedDirectional(
                top: 8,
                end: 8,
                child: IgnorePointer(
                  child: buildTypeLabel(tag, locale: locale),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _wantedCard(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    AppLocalizations loc,
    bool isAr, {
    String? listItemType,
  }) {
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
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
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
            if (listItemType case final String tag when tag.isNotEmpty)
              PositionedDirectional(
                top: 8,
                end: 8,
                child: IgnorePointer(
                  child: buildTypeLabel(
                    tag,
                    locale: isAr ? 'ar' : 'en',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _valuationCard(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    AppLocalizations loc,
    String locale, {
    String? listItemType,
  }) {
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
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
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
            if (listItemType case final String tag when tag.isNotEmpty)
              PositionedDirectional(
                top: 8,
                end: 8,
                child: IgnorePointer(
                  child: buildTypeLabel(tag, locale: locale),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatefulWidget {
  final AppLocalizations loc;
  final String propertyId;
  final bool featured;
  final int? featuredDaysLeft;
  final bool featuredUrgent;
  final bool canFeature;
  final VoidCallback onDelete;

  const _Actions({
    required this.loc,
    required this.propertyId,
    required this.featured,
    required this.featuredDaysLeft,
    required this.featuredUrgent,
    required this.canFeature,
    required this.onDelete,
  });

  @override
  State<_Actions> createState() => _ActionsState();
}

class _FeaturePlan {
  const _FeaturePlan({
    required this.durationDays,
    required this.priceKwd,
    required this.labelAr,
  });

  final int durationDays;
  final int priceKwd;
  final String labelAr;
}

class _ActionsState extends State<_Actions> {
  bool _loadingFeature = false;

  static const _plans = <_FeaturePlan>[
    _FeaturePlan(durationDays: 3, priceKwd: 5, labelAr: '3 أيام'),
    _FeaturePlan(durationDays: 7, priceKwd: 10, labelAr: '7 أيام'),
    _FeaturePlan(durationDays: 14, priceKwd: 15, labelAr: '14 يوم'),
    _FeaturePlan(durationDays: 30, priceKwd: 25, labelAr: '30 يوم'),
  ];

  Future<_FeaturePlan?> _pickPlan(BuildContext context) {
    return showModalBottomSheet<_FeaturePlan>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final bestValue = _plans[2]; // 14 days as a nice middle value
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                const Text(
                  'اختر مدة التمييز',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                ..._plans.map((p) {
                  final highlight = p == bestValue;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: InkWell(
                      onTap: () => Navigator.pop(ctx, p),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: highlight
                                ? Colors.blue.withValues(alpha: 0.45)
                                : Colors.black.withValues(alpha: 0.08),
                            width: highlight ? 1.6 : 1,
                          ),
                          color: highlight
                              ? Colors.blue.withValues(alpha: 0.06)
                              : Colors.white,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.star,
                              color: highlight ? Colors.blue : Colors.grey,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    p.labelAr,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                    ),
                                  ),
                                  if (highlight) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      'أفضل قيمة',
                                      style: TextStyle(
                                        color: Colors.blue.shade700,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Text(
                              '${p.priceKwd} د.ك',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _runFeatureFlow(BuildContext context) async {
    if (_loadingFeature) return;
    final plan = await _pickPlan(context);
    if (plan == null) return;

    setState(() => _loadingFeature = true);
    try {
      final ui = await PaymentServiceProvider.instance.payFeaturedAd(
        amountKwd: plan.priceKwd.toDouble(),
        propertyId: widget.propertyId,
        description: 'تمييز إعلان',
      );
      if (!ui.success) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إلغاء الدفع')),
        );
        return;
      }
      final pid = ui.paymentId?.trim() ?? '';
      if (pid.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('فشل الدفع: رقم العملية غير متوفر'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      await FeaturedPropertyService.featurePropertyPaid(
        propertyId: widget.propertyId,
        durationDays: plan.durationDays,
        amountKwd: plan.priceKwd.toDouble(),
        paymentId: pid,
        gateway: 'MyFatoorah',
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تم تمييز الإعلان بنجاح'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loadingFeature = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent =
        widget.featuredUrgent ? Colors.orange.shade800 : Colors.blue;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        if (widget.featured) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InkWell(
              onTap: _loadingFeature ? null : () => _runFeatureFlow(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loadingFeature) ...[
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      ),
                    ] else ...[
                      Icon(Icons.star, color: accent, size: 18),
                    ],
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        widget.featuredDaysLeft == null
                            ? widget.loc.extendFeature
                            : '${widget.loc.extendFeature} (${widget.featuredDaysLeft}d)',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (widget.canFeature)
          TextButton.icon(
            onPressed: _loadingFeature ? null : () => _runFeatureFlow(context),
            icon: _loadingFeature
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.star),
            style: TextButton.styleFrom(foregroundColor: Colors.blue),
            label: Text(
              widget.featured ? widget.loc.extendFeature : widget.loc.makeFeatured,
            ),
          ),
        TextButton.icon(
          onPressed: widget.onDelete,
          icon: const Icon(Icons.delete_outline),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          label: Text(widget.loc.delete),
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 72,
        height: 52,
        child: (url != null && url!.isNotEmpty)
            ? ListingThumbnailImage(
                imageUrl: url!,
                width: 72,
                height: 52,
                fit: BoxFit.cover,
              )
            : ColoredBox(
                color: Colors.grey[200]!,
                child: const Icon(Icons.home, color: Colors.black45),
              ),
      ),
    );
  }
}
