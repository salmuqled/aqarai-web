import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/utils/admin_deal_status_label.dart';
import 'package:aqarai_app/utils/crm_lead_priority.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:aqarai_app/services/firestore.dart';
import 'package:aqarai_app/pages/admin_dashboard_page.dart';
import 'package:aqarai_app/app/property_route.dart';
import 'package:aqarai_app/pages/wanted_details_page.dart';
import 'package:aqarai_app/pages/valuation_details_page.dart';
import 'package:aqarai_app/pages/admin_deal_detail_page.dart';
import 'package:aqarai_app/services/property_closure_service.dart';
import 'package:aqarai_app/services/admin_action_service.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/models/deal_pipeline.dart';
import 'package:aqarai_app/models/support_ticket.dart';
import 'package:aqarai_app/services/deal_admin_service.dart';
import 'package:aqarai_app/utils/financial_rules.dart';
import 'package:aqarai_app/utils/listing_display.dart';

const String kFunctionsRegion = 'us-central1';

/// عنصر مدمج في تبويب قيد المراجعة (إعلان، طلب مطلوب، أو طلب تقييم)
class _PendingMergedItem {
  final String type; // 'property' | 'wanted' | 'valuation'
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  _PendingMergedItem(this.type, this.doc);
}

enum AdminFilter {
  pending,
  sale,
  rent,
  wanted,
  chalets,
  valuations,
  matches,
  expiry,
  interested,
  closureRequests,
  deals,
  collection,
  support,
}

class AdminRequestsPage extends StatefulWidget {
  const AdminRequestsPage({super.key});

  @override
  State<AdminRequestsPage> createState() => _AdminRequestsPageState();
}

class _AdminRequestsPageState extends State<AdminRequestsPage> {
  AdminFilter _current = AdminFilter.pending;

  /// Deals sub-list: 0 = new, 1 = in progress (non-terminal, not new), 2 = overdue follow-up.
  int _selectedTab = 0;

  /// Interested tab CRM: `''` = all statuses; [DealStatus] value; or [_interestedFilterNegotiating].
  static const String _interestedFilterNegotiating = '__negotiating__';
  String _interestedStatusFilter = '';

  /// 0 = all time, 1 = today, 2 = last 7 days, 3 = last 30 days
  int _interestedDatePreset = 0;

  /// 0 = newest; 1 = follow-up time; 2 = smart priority (default)
  int _interestedSortMode = 2;

  final DealAdminService _dealAdminSvc = DealAdminService();

  static bool _dealStatusIsTerminal(String st) {
    final s = st.trim();
    return s == DealStatus.closed || s == DealStatus.notInterested;
  }

  /// Follow-up time is strictly before [now] − 30 minutes; excludes terminal deals.
  bool _dealMatchesOverdueFilter(Map<String, dynamic> data, DateTime now) {
    final st = (data['dealStatus'] ?? '').toString().trim();
    if (_dealStatusIsTerminal(st)) return false;
    final nf = data['nextFollowUpAt'];
    if (nf is! Timestamp) return false;
    final threshold = now.subtract(const Duration(minutes: 30));
    return nf.toDate().isBefore(threshold);
  }

  /// Matches [AdminFilter.deals] sub-tabs: جديد / قيد المتابعة / متأخر — terminal deals never appear.
  int _dealsCrmVisibleCount(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    return docs.where((doc) {
      final st = (doc.data()['dealStatus'] ?? '').toString().trim();
      return !_dealStatusIsTerminal(st);
    }).length;
  }

  @override
  void initState() {
    super.initState();
    _refreshAdminToken();
  }

  /// تحديث توكن الأدمن حتى يقرأ Firestore الطلبات (مثل wanted غير المعتمدة)
  Future<void> _refreshAdminToken() async {
    await FirebaseAuth.instance.currentUser?.getIdToken(true);
  }

  final Set<String> _loading = {};
  bool _isLoading(String key) => _loading.contains(key);
  void _setLoading(String key, bool v) {
    setState(() => v ? _loading.add(key) : _loading.remove(key));
  }

  final _priceFmt = NumberFormat.decimalPattern();

  static const Color _primaryBlue = Color(0xFF101046);

  String _fmtDate(Timestamp? ts) {
    final dt = ts?.toDate();
    if (dt == null) return '-';
    return DateFormat('yyyy/MM/dd – HH:mm').format(dt);
  }

  String _normalizeDigits(String input) {
    const ar = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const fa = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
    var s = input.trim();
    for (int i = 0; i < 10; i++) {
      s = s.replaceAll(ar[i], '$i').replaceAll(fa[i], '$i');
    }
    return s.replaceAll(RegExp(r'[^\d\.\-]'), '');
  }

  num? _parseNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    final s = _normalizeDigits(v.toString());
    return num.tryParse(s);
  }

  String _fmtPrice(dynamic raw) {
    final n = _parseNum(raw);
    return (n == null) ? (raw ?? '').toString() : _priceFmt.format(n);
  }

  Future<void> _callPhone(String raw) async {
    final phone = raw.trim();
    if (phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openWhatsApp(String raw) async {
    final phone = raw.replaceAll('+', '').trim();
    if (phone.isEmpty) return;
    final uri = Uri.parse('https://wa.me/$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ترجمة نوع العقار
  String _translateType(BuildContext context, String value) {
    final loc = AppLocalizations.of(context)!;
    switch (value.toLowerCase()) {
      case 'apartment':
        return loc.propertyType_apartment;
      case 'house':
        return loc.propertyType_house;
      case 'building':
        return loc.propertyType_building;
      case 'land':
        return loc.propertyType_land;
      case 'industrialland':
        return loc.propertyType_industrialLand;
      case 'shop':
        return loc.propertyType_shop;
      case 'office':
        return loc.propertyType_office;
      case 'chalet':
        return loc.propertyType_chalet;
      default:
        return value;
    }
  }

  // -------------------- Streams --------------------
  Stream<QuerySnapshot<Map<String, dynamic>>> _pending() => firestore
      .collection('properties')
      .where('approved', isEqualTo: false)
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  /// طلبات مطلوب غير معتمدة فقط (لدمجها في قيد المراجعة)
  Stream<QuerySnapshot<Map<String, dynamic>>> _wantedPending() => firestore
      .collection('wanted_requests')
      .where('approved', isEqualTo: false)
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  /// طلبات التقييم العقاري غير المعتمدة (لدمجها في قيد المراجعة)
  Stream<QuerySnapshot<Map<String, dynamic>>> _valuationsPending() => firestore
      .collection('valuations')
      .where('approved', isEqualTo: false)
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  /// دمج إعلانات + طلبات مطلوب + طلبات تقييم قيد المراجعة (للعرض والعداد)
  Stream<List<_PendingMergedItem>> _pendingMergedStream() {
    final c = StreamController<List<_PendingMergedItem>>.broadcast();
    List<QueryDocumentSnapshot<Map<String, dynamic>>> pendingProps = [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> pendingWanted = [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> pendingValuations = [];
    void emit() {
      final list = <_PendingMergedItem>[
        for (final d in pendingProps) _PendingMergedItem('property', d),
        for (final d in pendingWanted) _PendingMergedItem('wanted', d),
        for (final d in pendingValuations) _PendingMergedItem('valuation', d),
      ];
      list.sort((a, b) {
        final ta = a.doc.data()['createdAt'] as Timestamp?;
        final tb = b.doc.data()['createdAt'] as Timestamp?;
        final da = ta?.millisecondsSinceEpoch ?? 0;
        final db = tb?.millisecondsSinceEpoch ?? 0;
        return db.compareTo(da);
      });
      c.add(list);
    }

    StreamSubscription? sub1, sub2, sub3;
    sub1 = _pending().listen((s) {
      pendingProps = s.docs;
      emit();
    });
    sub2 = _wantedPending().listen((s) {
      pendingWanted = s.docs;
      emit();
    });
    sub3 = _valuationsPending().listen((s) {
      pendingValuations = s.docs;
      emit();
    });
    c.onCancel = () {
      sub1?.cancel();
      sub2?.cancel();
      sub3?.cancel();
    };
    return c.stream;
  }

  /// عداد قيد المراجعة = إعلانات + طلبات مطلوب + طلبات تقييم غير المعتمدة
  Stream<List<void>> _pendingCountStream() {
    final c = StreamController<List<void>>.broadcast();
    var lastPending = 0, lastWanted = 0, lastValuations = 0;
    void emit() =>
        c.add(List.filled(lastPending + lastWanted + lastValuations, null));
    StreamSubscription? sub1, sub2, sub3;
    sub1 = _pending().listen((s) {
      lastPending = s.docs.length;
      emit();
    });
    sub2 = _wantedPending().listen((s) {
      lastWanted = s.docs.length;
      emit();
    });
    sub3 = _valuationsPending().listen((s) {
      lastValuations = s.docs.length;
      emit();
    });
    c.onCancel = () {
      sub1?.cancel();
      sub2?.cancel();
      sub3?.cancel();
    };
    return c.stream;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _sale() => firestore
      .collection('properties')
      .where('serviceType', isEqualTo: 'sale')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _rent() => firestore
      .collection('properties')
      .where('serviceType', isEqualTo: 'rent')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _wanted() => firestore
      .collection('wanted_requests')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _chalets() => firestore
      .collection('properties')
      .where('type', isEqualTo: 'chalet')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _valuations() => firestore
      .collection('valuations')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _matches() => firestore
      .collection('match_logs')
      .orderBy('matchedAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _expiry() => firestore
      .collection('admin_inbox')
      .where('type', isEqualTo: 'expiry')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  /// Interest taps — same rows as `ensureInterestDeal` (`interestSource` discriminator).
  Stream<QuerySnapshot<Map<String, dynamic>>> _interested() => firestore
      .collection('deals')
      .where('interestSource', whereIn: ['property_detail', 'wanted_detail'])
      .orderBy('createdAt', descending: true)
      .limit(200)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _stream(AdminFilter f) {
    switch (f) {
      case AdminFilter.pending:
        return _pending();
      case AdminFilter.sale:
        return _sale();
      case AdminFilter.rent:
        return _rent();
      case AdminFilter.wanted:
        return _wanted();
      case AdminFilter.chalets:
        return _chalets();
      case AdminFilter.valuations:
        return _valuations();
      case AdminFilter.matches:
        return _matches();
      case AdminFilter.expiry:
        return _expiry();
      case AdminFilter.interested:
        return _interested();
      case AdminFilter.closureRequests:
        return _closureRequests();
      case AdminFilter.deals:
        return _deals();
      case AdminFilter.collection:
        return _collectionDeals();
      case AdminFilter.support:
        return _supportTickets();
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _deals() => firestore
      .collection('deals')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  /// Signed deals (commission not yet paid — filtered again in UI for missing flag).
  Stream<QuerySnapshot<Map<String, dynamic>>> _collectionDeals() => firestore
      .collection('deals')
      .where('dealStatus', isEqualTo: DealStatus.signed)
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _supportTickets() => firestore
      .collection('support_tickets')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _closureRequests() => firestore
      .collection('closure_requests')
      .where('status', isEqualTo: ClosureRequestStatus.pending)
      .orderBy('requestedAt', descending: true)
      .limit(100)
      .snapshots();

  // ---------------- Approve / Reject ----------------
  Future<void> _approveListing(String id) async {
    final key = "approve:$id";
    if (_isLoading(key)) return;
    _setLoading(key, true);

    try {
      final url = Uri.parse(
        "https://us-central1-aqarai-caf5d.cloudfunctions.net/approveListingV2",
      );

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"id": id, "approved": true, "action": "approve"}),
      );

      final data = jsonDecode(response.body);
      final ok = data["ok"] == true;
      final isAr = Localizations.localeOf(context).languageCode == 'ar';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? (isAr ? 'تم اعتماد الإعلان' : 'Listing approved') : 'Error',
          ),
        ),
      );
    } catch (e) {
      final isAr = Localizations.localeOf(context).languageCode == 'ar';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }

    _setLoading(key, false);
  }

  Future<void> _rejectListing(String id) async {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    String reason = '';

    final okDialog = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isAr ? 'رفض الإعلان' : 'Reject listing'),
        content: TextField(
          maxLines: 3,
          onChanged: (v) => reason = v,
          decoration: InputDecoration(
            hintText: isAr ? 'اذكر سبب الرفض (اختياري)' : 'Reason (optional)',
          ),
        ),
        actions: [
          TextButton(
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
            onPressed: () => Navigator.pop(context, false),
          ),
          FilledButton(
            child: Text(isAr ? 'رفض' : 'Reject'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (okDialog != true) return;

    final key = "reject:$id";
    if (_isLoading(key)) return;
    _setLoading(key, true);

    try {
      final url = Uri.parse(
        "https://us-central1-aqarai-caf5d.cloudfunctions.net/approveListingV2",
      );

      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "id": id,
          "approved": false,
          "action": "reject",
          "reason": reason,
        }),
      );

      final data = jsonDecode(response.body);
      final ok = data["ok"] == true;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? (isAr ? 'تم رفض الإعلان' : 'Listing rejected') : 'Error',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }

    _setLoading(key, false);
  }

  // ---------------- Cover Helper ----------------
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

  // -------------------- Tiles --------------------

  // كارد الإعلانات قيد المراجعة — نفس تصميم إعلاناتي
  Widget _buildPendingTile(
    AppLocalizations loc,
    Map<String, dynamic> d,
    String id,
  ) {
    final createdAt = d['createdAt'] as Timestamp?;
    final expiresAt = d['expiresAt'] as Timestamp?;
    final price = _fmtPrice(d['price']);
    final typeEn = (d['type'] ?? '').toString();
    final area = (d['area'] ?? d['area_id'] ?? '-').toString();
    final cover = _coverFrom(d['coverUrl'], d['images']);
    final typeLabel = _translateType(context, typeEn);
    final chaletName = listingChaletName(d);

    final approveKey = "approve:$id";
    final rejectKey = "reject:$id";

    return GestureDetector(
      onTap: () {
        context.pushPropertyDetails(propertyId: id, isAdminView: true);
      },
      child: Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // الصورة
              _Thumb(url: cover),

              const SizedBox(width: 12),

              // التفاصيل
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Surface the owner-provided chalet name to the admin
                    // reviewing the submission — they need to see it clearly
                    // so the name itself is part of the approve/reject
                    // decision. When absent, keep the historical
                    // "area • type" bold title unchanged.
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
                        '$area • $typeLabel',
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
                        '$area • $typeLabel',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                    const SizedBox(height: 6),

                    Text(
                      '${loc.price}: $price KWD',
                      style: const TextStyle(
                        fontSize: 15,
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 6),

                    Text(
                      '${loc.addedOn}: ${_fmtDate(createdAt)}\n'
                      '${loc.expiresOn}: ${_fmtDate(expiresAt)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // أزرار الاعتماد والرفض
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: _isLoading(approveKey)
                        ? null
                        : () => _approveListing(id),
                    icon: _isLoading(approveKey)
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified),
                    label: Text(loc.approve),
                    style: TextButton.styleFrom(foregroundColor: _primaryBlue),
                  ),
                  TextButton.icon(
                    onPressed: _isLoading(rejectKey)
                        ? null
                        : () => _rejectListing(id),
                    icon: _isLoading(rejectKey)
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.block),
                    label: Text(loc.reject),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _adminChaletModeChipLabel(AppLocalizations loc, String mode) {
    switch (mode) {
      case ChaletMode.daily:
        return loc.adminPropertyChaletModeDaily;
      case ChaletMode.monthly:
        return loc.adminPropertyChaletModeMonthly;
      case ChaletMode.sale:
        return loc.adminPropertyChaletModeSale;
      default:
        return loc.adminPropertyChaletModeDaily;
    }
  }

  Color _adminChaletModeChipColor(String mode) {
    switch (mode) {
      case ChaletMode.daily:
        return Colors.green.shade700;
      case ChaletMode.monthly:
        return Colors.blue.shade700;
      case ChaletMode.sale:
        return Colors.orange.shade800;
      default:
        return Colors.green.shade700;
    }
  }

  // كارد للبيع / للإيجار / الشاليهات — نفس تصميم إعلاناتي
  Widget _buildPropertyTile(
    AppLocalizations loc,
    Map<String, dynamic> d,
    String id,
  ) {
    final createdAt = d['createdAt'] as Timestamp?;
    final expiresAt = d['expiresAt'] as Timestamp?;
    final price = _fmtPrice(d['price']);
    final typeEn = (d['type'] ?? '').toString();
    final area = (d['area'] ?? d['area_id'] ?? '-').toString();
    final cover = _coverFrom(d['coverUrl'], d['images']);
    final typeLabel = _translateType(context, typeEn);
    final featuredUntil = d['featuredUntil'] as Timestamp?;
    final isFeatured =
        featuredUntil != null && featuredUntil.toDate().isAfter(DateTime.now());
    final String? chaletModeEffective = listingDataIsChalet(d)
        ? PropertyListingChaletMode.fromListingData(d).effectiveChaletMode
        : null;
    final chaletName = listingChaletName(d);

    return GestureDetector(
      onTap: () {
        context.pushPropertyDetails(propertyId: id, isAdminView: true);
      },
      child: Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumb(url: cover),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Owner-named chalets get their name as the bold title
                    // with the historical "area • type" demoted to a small
                    // subtitle. Non-named listings keep their original
                    // single-line title exactly.
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
                        '$area • $typeLabel',
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
                        '$area • $typeLabel',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                    const SizedBox(height: 6),

                    Text(
                      '${loc.price}: $price KWD',
                      style: const TextStyle(
                        fontSize: 15,
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    if (chaletModeEffective != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            '${loc.adminPropertyChaletModeLabel}: ',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Chip(
                            label: Text(
                              _adminChaletModeChipLabel(loc, chaletModeEffective),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            backgroundColor:
                                _adminChaletModeChipColor(chaletModeEffective),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                    ],

                    const SizedBox(height: 6),

                    Text(
                      '${loc.addedOn}: ${_fmtDate(createdAt)}\n'
                      '${loc.expiresOn}: ${_fmtDate(expiresAt)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // حالة الإعلان
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    d['approved'] == true ? '✅' : '⏳',
                    style: const TextStyle(fontSize: 20),
                  ),
                  if (isFeatured)
                    const Icon(Icons.star, color: Colors.amber, size: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteInterestDeal(String dealId) async {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    try {
      await firestore.collection('deals').doc(dealId).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isAr ? 'تم الحذف' : 'Deleted'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }
  }

  Color _interestedLeadStatusColor(String status) {
    final s = status.trim();
    switch (s) {
      case DealStatus.newLead:
        return Colors.blue.shade700;
      case DealStatus.contacted:
        return Colors.orange.shade800;
      case DealStatus.qualified:
      case DealStatus.booked:
      case DealStatus.signed:
        return Colors.purple.shade700;
      case DealStatus.closed:
        return Colors.green.shade700;
      case DealStatus.notInterested:
        return Colors.red.shade700;
      default:
        return Colors.blueGrey;
    }
  }

  String? _interestedLastNoteText(Map<String, dynamic> m) {
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

  DateTime? _interestedLeadDateTime(Map<String, dynamic> d) {
    final t =
        (d['leadCreatedAt'] as Timestamp?) ?? (d['createdAt'] as Timestamp?);
    return t?.toDate();
  }

  int _interestedCreatedMillis(Map<String, dynamic> d) {
    final t =
        (d['leadCreatedAt'] as Timestamp?) ?? (d['createdAt'] as Timestamp?);
    return t?.millisecondsSinceEpoch ?? 0;
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>>
  _filterAndSortInterestedDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    var out = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(docs);
    if (_interestedStatusFilter.isNotEmpty) {
      out = out.where((doc) {
        final st = (doc.data()['dealStatus'] ?? '').toString().trim();
        if (_interestedStatusFilter == _interestedFilterNegotiating) {
          return st == DealStatus.qualified ||
              st == DealStatus.booked ||
              st == DealStatus.signed;
        }
        return st == _interestedStatusFilter;
      }).toList();
    }
    final now = DateTime.now();
    if (_interestedDatePreset != 0) {
      out = out.where((doc) {
        final dt = _interestedLeadDateTime(doc.data());
        if (dt == null) return false;
        switch (_interestedDatePreset) {
          case 1:
            return dt.year == now.year &&
                dt.month == now.month &&
                dt.day == now.day;
          case 2:
            return dt.isAfter(now.subtract(const Duration(days: 7)));
          case 3:
            return dt.isAfter(now.subtract(const Duration(days: 30)));
          default:
            return true;
        }
      }).toList();
    }
    if (_interestedSortMode == 1) {
      out.sort((a, b) {
        final ma = a.data();
        final mb = b.data();
        final ta = ma['nextFollowUpAt'];
        final tb = mb['nextFollowUpAt'];
        final tsa = ta is Timestamp ? ta : null;
        final tsb = tb is Timestamp ? tb : null;
        if (tsa != null && tsb != null) return tsa.compareTo(tsb);
        if (tsa != null) return -1;
        if (tsb != null) return 1;
        final ca = _interestedCreatedMillis(ma);
        final cb = _interestedCreatedMillis(mb);
        return cb.compareTo(ca);
      });
    } else if (_interestedSortMode == 2) {
      out.sort((a, b) {
        final pa = crmComputeLeadPriority(a.data(), now).sortKey;
        final pb = crmComputeLeadPriority(b.data(), now).sortKey;
        if (pa != pb) return pa.compareTo(pb);
        return _interestedCreatedMillis(
          b.data(),
        ).compareTo(_interestedCreatedMillis(a.data()));
      });
    } else {
      out.sort(
        (a, b) => _interestedCreatedMillis(
          b.data(),
        ).compareTo(_interestedCreatedMillis(a.data())),
      );
    }
    return out;
  }

  Future<void> _setInterestedDealStatus(
    String dealId,
    String newStatus,
    AppLocalizations loc,
    bool isAr,
  ) async {
    try {
      await _dealAdminSvc.setPipelineStatus(
        dealId: dealId,
        newStatus: newStatus,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isAr ? 'تم تحديث الحالة' : 'Status updated')),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      final msg = e.message == 'final_price_required'
          ? loc.adminDealFinalPriceRequired
          : e.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }
  }

  Future<void> _appendInterestedQuickNote(
    String dealId,
    AppLocalizations loc,
    bool isAr,
  ) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'ملاحظة سريعة' : 'Quick note'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: isAr ? 'اكتب الملاحظة…' : 'Type a note…',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.adminDealSaveNote),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      ctrl.dispose();
      return;
    }
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (text.isEmpty) return;
    try {
      await _dealAdminSvc.appendDealNote(dealId: dealId, text: text);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(loc.adminDealNoteSaved)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }
  }

  String _crmPriorityLabel(CrmLeadPriority p, bool isAr) {
    switch (p) {
      case CrmLeadPriority.urgent:
        return isAr ? 'عاجل' : 'Urgent';
      case CrmLeadPriority.high:
        return isAr ? 'أولوية عالية' : 'High';
      case CrmLeadPriority.medium:
        return isAr ? 'متوسطة' : 'Medium';
      case CrmLeadPriority.low:
        return isAr ? 'منخفضة' : 'Low';
    }
  }

  Color _crmPriorityBadgeColor(CrmLeadPriority p) {
    switch (p) {
      case CrmLeadPriority.urgent:
        return Colors.red.shade800;
      case CrmLeadPriority.high:
        return Colors.blue.shade800;
      case CrmLeadPriority.medium:
        return Colors.deepOrange.shade800;
      case CrmLeadPriority.low:
        return Colors.blueGrey.shade600;
    }
  }

  Widget _buildInterestedCrmToolbar(
    AppLocalizations loc,
    bool isAr, {
    required int overdueCount,
  }) {
    String statusFilterLabel(String key) {
      if (key.isEmpty) return isAr ? 'كل الحالات' : 'All statuses';
      if (key == _interestedFilterNegotiating) {
        return isAr
            ? 'تفاوض (مؤهل / محجوز / موقّع)'
            : 'Negotiating (qualified / booked / signed)';
      }
      return getDealStatusLabel(context, key);
    }

    String dateLabel(int preset) {
      switch (preset) {
        case 1:
          return isAr ? 'اليوم' : 'Today';
        case 2:
          return isAr ? 'آخر ٧ أيام' : 'Last 7 days';
        case 3:
          return isAr ? 'آخر ٣٠ يوماً' : 'Last 30 days';
        default:
          return isAr ? 'كل التواريخ' : 'All dates';
      }
    }

    final statusKeys = <String>[
      '',
      DealStatus.newLead,
      DealStatus.contacted,
      _interestedFilterNegotiating,
      DealStatus.qualified,
      DealStatus.booked,
      DealStatus.signed,
      DealStatus.closed,
      DealStatus.notInterested,
    ];

    return Material(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isAr ? 'تصفية وترتيب' : 'Filter & sort',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: statusKeys.contains(_interestedStatusFilter)
                        ? _interestedStatusFilter
                        : '',
                    items: statusKeys
                        .map(
                          (k) => DropdownMenuItem<String>(
                            value: k,
                            child: Text(
                              statusFilterLabel(k),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _interestedStatusFilter = v);
                    },
                  ),
                ),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _interestedDatePreset.clamp(0, 3),
                    items: [0, 1, 2, 3]
                        .map(
                          (p) => DropdownMenuItem<int>(
                            value: p,
                            child: Text(dateLabel(p)),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _interestedDatePreset = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (overdueCount > 0)
                  Chip(
                    avatar: Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: Colors.red.shade900,
                    ),
                    label: Text(
                      isAr
                          ? 'متابعة متأخرة ($overdueCount)'
                          : 'Overdue follow-up ($overdueCount)',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.red.shade900,
                        fontSize: 12,
                      ),
                    ),
                    backgroundColor: Colors.red.shade100,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ChoiceChip(
                  label: Text(isAr ? 'الأولوية' : 'Priority'),
                  selected: _interestedSortMode == 2,
                  onSelected: (_) => setState(() => _interestedSortMode = 2),
                ),
                ChoiceChip(
                  label: Text(isAr ? 'الأحدث' : 'Newest'),
                  selected: _interestedSortMode == 0,
                  onSelected: (_) => setState(() => _interestedSortMode = 0),
                ),
                ChoiceChip(
                  label: Text(isAr ? 'موعد المتابعة' : 'Follow-up time'),
                  selected: _interestedSortMode == 1,
                  onSelected: (_) => setState(() => _interestedSortMode = 1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // كارد المهتم — صف `deals` من زر "أنا مهتم" (interestSource)
  Widget _buildInterestedTile(
    AppLocalizations loc,
    Map<String, dynamic> d,
    String dealId,
  ) {
    final createdAt =
        (d['leadCreatedAt'] as Timestamp?) ?? (d['createdAt'] as Timestamp?);
    final propertyId = (d['propertyId'] ?? '').toString();
    final wantedId = (d['wantedId'] ?? '').toString();
    final typeEn = (d['type'] ?? '').toString();
    final serviceType = (d['serviceType'] ?? '').toString();
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final area = isAr
        ? ((d['areaAr'] ?? d['area']) ?? '-').toString()
        : ((d['areaEn'] ?? d['area']) ?? '-').toString();
    final typeLabel = typeEn.isEmpty
        ? (wantedId.isNotEmpty ? loc.wanted : '')
        : _translateType(context, typeEn);
    final propertyTitle = (d['propertyTitle'] ?? '').toString();
    final headline = propertyTitle.isNotEmpty
        ? propertyTitle
        : (typeLabel.isNotEmpty ? '$area • $typeLabel' : area);
    final clientPhone = (d['clientPhone'] ?? '').toString().trim();
    final isWantedLead = typeEn == 'wanted' || wantedId.isNotEmpty;
    final serviceLabel = isWantedLead
        ? loc.wanted
        : serviceType == 'sale'
        ? loc.forSale
        : serviceType == 'rent'
        ? loc.forRent
        : loc.forExchange;

    final dealStatusRaw = (d['dealStatus'] ?? d['status'] ?? '')
        .toString()
        .trim();
    final pipelineMenu = List<String>.from(DealPipelineStatus.ordered);
    if (dealStatusRaw.isNotEmpty && !pipelineMenu.contains(dealStatusRaw)) {
      pipelineMenu.insert(0, dealStatusRaw);
    }
    final dealStatusDropdownValue =
        pipelineMenu.contains(dealStatusRaw) && dealStatusRaw.isNotEmpty
        ? dealStatusRaw
        : DealStatus.newLead;
    final statusColor = _interestedLeadStatusColor(dealStatusRaw);
    final nextFu = d['nextFollowUpAt'];
    final lastNote = _interestedLastNoteText(d);
    final now = DateTime.now();
    final overdueFollowUp = crmIsFollowUpOverdue(d, now);
    final priority = crmComputeLeadPriority(d, now);
    final priorityColor = _crmPriorityBadgeColor(priority);

    void openListing() {
      if (isWantedLead && wantedId.isNotEmpty) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                WantedDetailsPage(wantedId: wantedId, isAdminView: true),
          ),
        );
        return;
      }
      if (propertyId.isNotEmpty) {
        context.pushPropertyDetails(
          propertyId: propertyId,
          isAdminView: true,
        );
      }
    }

    return Card(
      elevation: 3,
      clipBehavior: Clip.antiAlias,
      color: overdueFollowUp ? Colors.red.shade50 : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: overdueFollowUp
            ? BorderSide(color: Colors.red.shade700, width: 2)
            : BorderSide.none,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (overdueFollowUp)
            Material(
              color: Colors.red.shade700,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 12,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isAr
                            ? 'متابعة متأخرة — يتطلب إجراء'
                            : 'Overdue follow-up — needs attention',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: openListing,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 56,
                                height: 48,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  color: const Color(0xFFE8F5E9),
                                ),
                                child: const Icon(
                                  Icons.thumb_up,
                                  color: Color(0xFF25D366),
                                  size: 26,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      headline,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      serviceLabel,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: Colors.green,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (clientPhone.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      SelectableText(
                                        clientPhone,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: statusColor.withValues(
                                              alpha: 0.12,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            border: Border.all(
                                              color: statusColor.withValues(
                                                alpha: 0.45,
                                              ),
                                            ),
                                          ),
                                          child: Text(
                                            getDealStatusLabel(
                                              context,
                                              dealStatusRaw.isNotEmpty
                                                  ? dealStatusRaw
                                                  : DealStatus.newLead,
                                            ),
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: statusColor,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                          decoration: BoxDecoration(
                                            color: priorityColor.withValues(
                                              alpha: 0.12,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            border: Border.all(
                                              color: priorityColor.withValues(
                                                alpha: 0.45,
                                              ),
                                            ),
                                          ),
                                          child: Text(
                                            _crmPriorityLabel(priority, isAr),
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: priorityColor,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (nextFu is Timestamp) ...[
                                      const SizedBox(height: 6),
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Icon(
                                            Icons.event_available,
                                            size: 16,
                                            color: Colors.indigo.shade700,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              '${loc.adminDealFollowUpDateLabel}: ${_fmtDate(nextFu)}',
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: Colors.indigo.shade800,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    if (lastNote != null &&
                                        lastNote.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        '${loc.adminFollowupLastNoteLabel}:',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.grey.shade700,
                                        ),
                                      ),
                                      Text(
                                        lastNote,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Colors.grey.shade800,
                                          height: 1.35,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(height: 6),
                                    Text(
                                      '${loc.addedOn}: ${_fmtDate(createdAt)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.chevron_left,
                                color: Colors.grey.shade500,
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        Navigator.push<void>(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => AdminDealDetailPage(dealId: dealId),
                          ),
                        );
                      },
                      icon: const Icon(
                        Icons.open_in_new,
                        color: Color(0xFF101046),
                      ),
                      tooltip: isAr ? 'تفاصيل الصفقة' : 'Deal details',
                    ),
                    IconButton(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(isAr ? 'حذف الصفقة' : 'Delete deal'),
                            content: Text(
                              isAr
                                  ? 'سيتم حذف سجل الصفقة نهائياً من النظام. متابعة؟'
                                  : 'This removes the deal document permanently. Continue?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: Text(loc.cancel),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red,
                                ),
                                onPressed: () => Navigator.pop(ctx, true),
                                child: Text(loc.delete),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) await _deleteInterestDeal(dealId);
                      },
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      tooltip: isAr ? 'حذف الصفقة' : 'Delete deal',
                    ),
                  ],
                ),
                const Divider(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: isAr ? 'تغيير الحالة' : 'Change status',
                          border: const OutlineInputBorder(),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isDense: true,
                            isExpanded: true,
                            value: dealStatusDropdownValue,
                            items: pipelineMenu
                                .map(
                                  (s) => DropdownMenuItem<String>(
                                    value: s,
                                    child: Text(getDealStatusLabel(context, s)),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              if (v == null || v == dealStatusDropdownValue) {
                                return;
                              }
                              _setInterestedDealStatus(dealId, v, loc, isAr);
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () =>
                          _appendInterestedQuickNote(dealId, loc, isAr),
                      icon: const Icon(Icons.note_add_outlined),
                      tooltip: isAr ? 'ملاحظة سريعة' : 'Quick note',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _approveWanted(String wantedId) async {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    try {
      await firestore.collection('wanted_requests').doc(wantedId).update({
        'approved': true,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr ? 'تم اعتماد طلب المطلوب' : 'Wanted request approved',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }
  }

  Future<void> _rejectWanted(String wantedId) async {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'رفض طلب مطلوب' : 'Reject wanted request'),
        content: Text(
          isAr
              ? 'هل تريد رفض هذا الطلب؟ سيُحذف من القائمة.'
              : 'Reject this request? It will be removed from the list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.reject),
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
          content: Text(isAr ? 'تم رفض الطلب' : 'Request rejected'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }
  }

  /// تمييز طلب مطلوب ٧ أيام (من لوحة الأدمن)
  Future<void> _makeWantedFeatured(String wantedId) async {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final end = DateTime.now().add(const Duration(days: 7));
    try {
      await firestore.collection('wanted_requests').doc(wantedId).update({
        'featuredUntil': Timestamp.fromDate(end),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr
                ? 'تم تمييز الطلب ٧ أيام'
                : 'Wanted request featured for 7 days',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }
  }

  Future<void> _approveValuation(String valuationId) async {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    try {
      await firestore.collection('valuations').doc(valuationId).update({
        'approved': true,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAr ? 'تم اعتماد طلب التقييم' : 'Valuation request approved',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }
  }

  Future<void> _rejectValuation(String valuationId) async {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'رفض طلب التقييم' : 'Reject valuation request'),
        content: Text(
          isAr
              ? 'هل تريد رفض هذا الطلب؟ سيُحذف من القائمة.'
              : 'Reject this request? It will be removed from the list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.reject),
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
          content: Text(isAr ? 'تم رفض الطلب' : 'Request rejected'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(isAr ? 'خطأ: $e' : 'Error: $e')));
    }
  }

  // كارد المطلوب — النقر يفتح تفاصيل الطلب
  Widget _buildWantedTile(
    AppLocalizations loc,
    Map<String, dynamic> d,
    String wantedId,
  ) {
    final createdAt = d['createdAt'] as Timestamp?;
    final typeEn = (d['type'] ?? '').toString();
    final area = (d['area'] ?? d['area_id'] ?? '-').toString();
    final typeLabel = _translateType(context, typeEn);
    final minP = _fmtPrice(d['minPrice']);
    final maxP = _fmtPrice(d['maxPrice']);
    final approved = d['approved'] == true;
    final featuredUntil = d['featuredUntil'] as Timestamp?;
    final isFeatured =
        featuredUntil != null && featuredUntil.toDate().isAfter(DateTime.now());
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                WantedDetailsPage(wantedId: wantedId, isAdminView: true),
          ),
        );
      },
      borderRadius: BorderRadius.circular(10),
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
                  size: 32,
                ),
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$area • $typeLabel',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (approved)
                          Text(
                            ' ✅',
                            style: TextStyle(
                              color: Colors.green[700],
                              fontSize: 14,
                            ),
                          )
                        else
                          Text(
                            ' ⏳',
                            style: TextStyle(
                              color: Colors.orange[700],
                              fontSize: 14,
                            ),
                          ),
                      ],
                    ),

                    const SizedBox(height: 6),

                    Text(
                      '${loc.budget}: $minP - $maxP KWD',
                      style: const TextStyle(
                        fontSize: 15,
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 6),

                    Text(
                      '${loc.addedOn}: ${_fmtDate(createdAt)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),

              if (!approved)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _primaryBlue,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: () => _approveWanted(wantedId),
                    child: Text(
                      isAr ? 'اعتماد' : 'Approve',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isFeatured)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.star,
                            size: 18,
                            color: Colors.amber[700],
                          ),
                        ),
                      TextButton.icon(
                        onPressed: () => _makeWantedFeatured(wantedId),
                        icon: Icon(
                          isFeatured ? Icons.star : Icons.star_border,
                          size: 18,
                          color: Colors.amber[800],
                        ),
                        label: Text(
                          isAr
                              ? (isFeatured ? 'تمديد التمييز' : 'تمييز')
                              : (isFeatured ? 'Extend' : 'Feature'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      const Icon(Icons.chevron_left, color: Colors.grey),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // كارد التقييمات — النقر يفتح تفاصيل الطلب
  Widget _buildValuationTile(
    AppLocalizations loc,
    Map<String, dynamic> d,
    String valuationId,
  ) {
    final createdAt = d['createdAt'] as Timestamp?;
    final owner = d['ownerName']?.toString() ?? '';
    final phone = d['phone']?.toString() ?? '';
    final gov = d['governorate']?.toString() ?? '';
    final area = d['area']?.toString() ?? '';
    final pType = d['propertyType']?.toString() ?? '-';
    final pArea = d['propertyArea']?.toString() ?? '-';

    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ValuationDetailsPage(valuationId: valuationId),
          ),
        );
      },
      borderRadius: BorderRadius.circular(10),
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
                  size: 32,
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

                    const SizedBox(height: 6),

                    Text(
                      '${loc.valuation_propertyType}: $pType | ${loc.valuation_propertyArea}: $pArea',
                      style: const TextStyle(fontSize: 13),
                    ),

                    const SizedBox(height: 4),

                    Text(
                      '${loc.addedOn}: ${_fmtDate(createdAt)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.call, color: Colors.green),
                    onPressed: phone.isEmpty ? null : () => _callPhone(phone),
                  ),
                  IconButton(
                    icon: const Icon(Icons.sms, color: Colors.blue),
                    onPressed: phone.isEmpty
                        ? null
                        : () => _openWhatsApp(phone),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _deleteValuation(valuationId),
                  ),
                ],
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

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

  // كارد المطابقات — مع أزرار فتح الإعلان وطلب المطلوب
  Widget _buildMatchTile(AppLocalizations loc, Map<String, dynamic> d) {
    final matchedAt = d['matchedAt'] as Timestamp?;
    final propertyId = d['propertyId']?.toString() ?? '';
    final wantedId = d['wantedId']?.toString() ?? '';
    final typeEn = d['type']?.toString() ?? '';
    final typeLabel = _translateType(context, typeEn);
    final area = (d['area_id'] ?? d['area'] ?? '-').toString();
    final price = _fmtPrice(d['price']);
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Card(
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
              child: const Icon(Icons.link, color: Colors.black45, size: 32),
            ),

            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${loc.type}: $typeLabel • ${loc.areaLabel}: $area',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 6),

                  Text(
                    '${loc.price}: $price KWD',
                    style: const TextStyle(
                      fontSize: 15,
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 4),

                  Text(
                    '${loc.matched}: ${_fmtDate(matchedAt)}',
                    style: const TextStyle(fontSize: 13),
                  ),

                  const SizedBox(height: 10),

                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: propertyId.isEmpty
                            ? null
                            : () {
                                context.pushPropertyDetails(
                                  propertyId: propertyId,
                                  isAdminView: true,
                                );
                              },
                        icon: const Icon(Icons.home_work, size: 18),
                        label: Text(
                          isAr ? 'الإعلان' : 'Ad',
                          style: const TextStyle(fontSize: 12),
                        ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: wantedId.isEmpty
                            ? null
                            : () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => WantedDetailsPage(
                                      wantedId: wantedId,
                                      isAdminView: true,
                                    ),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.search, size: 18),
                        label: Text(
                          isAr ? 'المطلوب' : 'Wanted',
                          style: const TextStyle(fontSize: 12),
                        ),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          minimumSize: Size.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // كارد المنتهية
  Widget _buildExpiryTile(AppLocalizations loc, Map<String, dynamic> d) {
    final createdAt = d['createdAt'] as Timestamp?;
    final expiredAt = d['expiredAt'] as Timestamp?;
    final title = d['title']?.toString() ?? loc.adLabel;
    final owner = (d['ownerName'] ?? d['ownerId'] ?? '').toString();
    final area = (d['area'] ?? d['area_id'] ?? '').toString();

    return Card(
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
                Icons.history_toggle_off,
                color: Colors.black45,
                size: 32,
              ),
            ),

            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$title${area.isNotEmpty ? ' • $area' : ''}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 6),

                  if (owner.isNotEmpty)
                    Text(
                      'المالك: $owner',
                      style: const TextStyle(fontSize: 13),
                    ),

                  if (expiredAt != null)
                    Text(
                      'تاريخ الانتهاء: ${_fmtDate(expiredAt)}',
                      style: const TextStyle(fontSize: 13, color: Colors.red),
                    ),

                  Text(
                    '${loc.addedOn}: ${_fmtDate(createdAt)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),

            const Icon(Icons.chevron_left, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildClosureRequestTile(
    AppLocalizations loc,
    Map<String, dynamic> d,
    String requestId,
    bool isAr,
  ) {
    final title = (d['title'] ?? '').toString();
    final area = (d['areaAr'] ?? '').toString();
    final gov = (d['governorateAr'] ?? '').toString();
    final areaEn = (d['areaEn'] ?? '').toString();
    final govEn = (d['governorateEn'] ?? '').toString();
    final type = (d['propertyType'] ?? '').toString();
    final svc = (d['serviceType'] ?? '').toString();
    final req = (d['requestType'] ?? '').toString();
    final price = _fmtPrice(d['listingPrice']);
    final phone = (d['ownerPhone'] ?? '').toString();
    final pid = (d['propertyId'] ?? '').toString();
    final owner = (d['ownerId'] ?? '').toString();
    final at = d['requestedAt'] as Timestamp?;

    Future<void> approve() async {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      try {
        final dealId = await PropertyClosureService().approveClosureRequest(
          requestId: requestId,
          adminUid: uid,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isAr ? 'تم اعتماد الإغلاق' : 'Closure approved'),
          ),
        );
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => AdminDealDetailPage(dealId: dealId),
          ),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }

    Future<void> reject() async {
      var note = '';
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(isAr ? 'رفض الطلب' : 'Reject'),
          content: TextField(
            decoration: InputDecoration(
              hintText: isAr ? 'ملاحظة (اختياري)' : 'Note (optional)',
            ),
            onChanged: (v) => note = v,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(isAr ? 'رفض' : 'Reject'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      try {
        await PropertyClosureService().rejectClosureRequest(
          requestId: requestId,
          adminUid: uid,
          adminNote: note.isEmpty ? null : note,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isAr ? 'تم الرفض وإرجاع الإعلان' : 'Rejected; listing restored',
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty)
              Text(
                '${isAr ? "العنوان" : "Title"}: $title',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            Text(
              '$area • ${_translateType(context, type)}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            if (areaEn.isNotEmpty || govEn.isNotEmpty)
              Text(
                'EN: $govEn · $areaEn',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            Text('${isAr ? "المحافظة" : "Gov"}: $gov'),
            Text(
              '${isAr ? "الخدمة" : "Service"}: $svc → ${isAr ? "طلب إغلاق" : "close"}: $req',
            ),
            Text(
              '${isAr ? "حالة الطلب" : "Request status"}: ${isAr ? "معلّق" : "Pending"}',
            ),
            Text('${loc.price}: $price KWD'),
            Text('${isAr ? "المالك" : "Owner"}: $owner'),
            if (phone.isNotEmpty) Text('☎ $phone'),
            Text('${loc.addedOn}: ${_fmtDate(at)}'),
            Text('propertyId: $pid'),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: approve,
                  icon: const Icon(Icons.check_circle, color: Colors.green),
                  label: Text(isAr ? 'اعتماد الإغلاق' : 'Approve'),
                ),
                TextButton.icon(
                  onPressed: reject,
                  icon: const Icon(Icons.cancel, color: Colors.red),
                  label: Text(isAr ? 'رفض' : 'Reject'),
                ),
                TextButton.icon(
                  onPressed: () {
                    context.pushPropertyDetails(
                      propertyId: pid,
                      isAdminView: true,
                    );
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: Text(isAr ? 'الإعلان' : 'Listing'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(
    AppLocalizations loc,
    AdminFilter f,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    bool isAr,
  ) {
    final d = doc.data();
    switch (f) {
      case AdminFilter.pending:
        return _buildPendingTile(loc, d, doc.id);
      case AdminFilter.sale:
      case AdminFilter.rent:
      case AdminFilter.chalets:
        return _buildPropertyTile(loc, d, doc.id);
      case AdminFilter.wanted:
        return _buildWantedTile(loc, d, doc.id);
      case AdminFilter.valuations:
        return _buildValuationTile(loc, d, doc.id);
      case AdminFilter.matches:
        return _buildMatchTile(loc, d);
      case AdminFilter.expiry:
        return _buildExpiryTile(loc, d);
      case AdminFilter.interested:
        return _buildInterestedTile(loc, d, doc.id);
      case AdminFilter.closureRequests:
        return _buildClosureRequestTile(loc, d, doc.id, isAr);
      case AdminFilter.deals:
      case AdminFilter.collection:
        return _buildDealTile(loc, d, doc.id);
      case AdminFilter.support:
        return _buildSupportTicketTile(loc, d, doc.id, isAr);
    }
  }

  Widget _buildDealTile(
    AppLocalizations loc,
    Map<String, dynamic> d,
    String dealId,
  ) {
    final title = (d['propertyTitle'] ?? d['title'] ?? '').toString();
    final st = (d['dealStatus'] ?? '').toString();
    final fp = _fmtPrice(d['finalPrice']);
    final lp = _fmtPrice(d['propertyPrice'] ?? d['listingPrice']);
    final pid = (d['propertyId'] ?? '').toString();
    return Card(
      child: InkWell(
        onTap: () {
          Navigator.push<void>(
            context,
            MaterialPageRoute<void>(
              builder: (_) => AdminDealDetailPage(dealId: dealId),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.isEmpty ? dealId : title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${loc.adminDealPipelineStatus}: ${st.trim().isEmpty ? '—' : getDealStatusLabel(context, st)}',
              ),
              Text('${loc.adminDealPropertyPrice}: $lp KWD'),
              Text('${loc.adminDealFinalPrice}: $fp KWD'),
              if (pid.isNotEmpty)
                Text(
                  'propertyId: $pid',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _supportCategoryLabel(AppLocalizations loc, String key) {
    switch (key) {
      case SupportTicketCategory.general:
        return loc.supportCategoryGeneral;
      case SupportTicketCategory.bug:
        return loc.supportCategoryBug;
      case SupportTicketCategory.propertyInquiry:
        return loc.supportCategoryPropertyInquiry;
      case SupportTicketCategory.payment:
        return loc.supportCategoryPayment;
      default:
        return key;
    }
  }

  String _supportStatusLabel(AppLocalizations loc, String status) {
    switch (status) {
      case SupportTicketStatus.inProgress:
        return loc.supportTicketStatusInProgress;
      case SupportTicketStatus.resolved:
        return loc.supportTicketStatusResolved;
      default:
        return loc.supportTicketStatusOpen;
    }
  }

  Color _supportStatusColor(String status) {
    switch (status) {
      case SupportTicketStatus.resolved:
        return Colors.green.shade700;
      case SupportTicketStatus.inProgress:
        return Colors.orange.shade800;
      default:
        return Colors.blue.shade800;
    }
  }

  Widget _buildSupportTicketTile(
    AppLocalizations loc,
    Map<String, dynamic> d,
    String ticketId,
    bool isAr,
  ) {
    final subject = (d['subject'] ?? '').toString();
    final message = (d['message'] ?? '').toString();
    final userName = (d['userName'] ?? '').toString();
    final userPhone = (d['userPhone'] ?? '').toString();
    final userId = (d['userId'] ?? '').toString();
    final category = (d['category'] ?? '').toString();
    final status = (d['status'] ?? SupportTicketStatus.open).toString();
    final createdAt = d['createdAt'] as Timestamp?;

    Future<void> setStatus(String newStatus) async {
      try {
        await AdminActionService.updateSupportTicketStatus(
          ticketId: ticketId,
          status: newStatus,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.supportTicketUpdated)));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${loc.errorLabel}: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }

    Future<void> removeTicket() async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(loc.supportDeleteTicket),
          content: Text(loc.supportDeleteTicketConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(loc.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(loc.delete),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await AdminActionService.deleteSupportTicket(ticketId);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.supportTicketDeleted)));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${loc.errorLabel}: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    subject.isEmpty ? '—' : subject,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _supportStatusColor(status),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _supportStatusLabel(loc, status),
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${loc.supportCategoryLabel}: ${_supportCategoryLabel(loc, category)}',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
            ),
            const SizedBox(height: 4),
            Text(
              '${loc.supportUserLine}: $userName',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
            ),
            if (userPhone.isNotEmpty)
              Text(
                '☎ $userPhone',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
              ),
            Text(
              'uid: $userId',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            Text(
              '${loc.addedOn}: ${_fmtDate(createdAt)}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const Divider(height: 20),
            SelectableText(
              message.isEmpty ? '—' : message,
              style: const TextStyle(fontSize: 14, height: 1.35),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (userPhone.isNotEmpty) ...[
                  FilledButton.tonalIcon(
                    onPressed: () => _callPhone(userPhone),
                    icon: const Icon(Icons.call, size: 18),
                    label: Text(isAr ? 'اتصال' : 'Call'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _openWhatsApp(userPhone),
                    icon: const Icon(Icons.chat, size: 18),
                    label: Text(isAr ? 'واتساب' : 'WhatsApp'),
                  ),
                ],
                if (status != SupportTicketStatus.inProgress)
                  TextButton.icon(
                    onPressed: () => setStatus(SupportTicketStatus.inProgress),
                    icon: const Icon(Icons.hourglass_top, size: 18),
                    label: Text(loc.supportMarkInProgress),
                  ),
                if (status != SupportTicketStatus.resolved)
                  TextButton.icon(
                    onPressed: () => setStatus(SupportTicketStatus.resolved),
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: Text(loc.supportMarkResolved),
                  ),
                TextButton.icon(
                  onPressed: removeTicket,
                  icon: Icon(Icons.delete_outline, color: Colors.red.shade700),
                  label: Text(
                    loc.supportDeleteTicket,
                    style: TextStyle(color: Colors.red.shade700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.adminFollowup),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: isAr ? 'لوحة التحليلات' : 'Analytics dashboard',
            icon: const Icon(Icons.insights_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AdminDashboardPage(),
                ),
              );
            },
          ),
        ],
      ),

      body: Column(
        children: [
          // Tabs
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(
                spacing: 8,
                children: [
                  _badgePending(loc),
                  _badge(loc.forSale, loc.forSale, AdminFilter.sale, _sale()),
                  _badge(loc.forRent, loc.forRent, AdminFilter.rent, _rent()),
                  _badge(loc.wanted, loc.wanted, AdminFilter.wanted, _wanted()),
                  _badge(
                    loc.chalets,
                    loc.chalets,
                    AdminFilter.chalets,
                    _chalets(),
                  ),
                  _badge(
                    loc.valuation,
                    loc.valuation,
                    AdminFilter.valuations,
                    _valuations(),
                  ),
                  _badge(
                    loc.matches,
                    loc.matches,
                    AdminFilter.matches,
                    _matches(),
                  ),
                  _badge(
                    loc.expired,
                    loc.expired,
                    AdminFilter.expiry,
                    _expiry(),
                  ),
                  _badge(
                    loc.interestedDetails,
                    loc.interestedDetails,
                    AdminFilter.interested,
                    _interested(),
                  ),
                  _badge(
                    'Closure',
                    'طلبات الإغلاق',
                    AdminFilter.closureRequests,
                    _closureRequests(),
                  ),
                  _badge(
                    loc.adminDealsTab,
                    loc.adminDealsTab,
                    AdminFilter.deals,
                    _deals(),
                    docCount: _dealsCrmVisibleCount,
                  ),
                  _badge(
                    loc.adminDealsCollectionTab,
                    loc.adminDealsCollectionTab,
                    AdminFilter.collection,
                    _collectionDeals(),
                    docCount: (docs) => docs
                        .where((doc) => !isPaid(doc.data()))
                        .length,
                  ),
                  _badge(
                    loc.supportTabEn,
                    loc.supportTabAr,
                    AdminFilter.support,
                    _supportTickets(),
                  ),
                ],
              ),
            ),
          ),

          const Divider(height: 1),

          if (_current == AdminFilter.deals) ...[
            _buildDealsSubTabs(loc),
            const Divider(height: 1),
          ],

          if (_current == AdminFilter.interested) ...[
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _interested(),
              builder: (context, snap) {
                final docs = snap.data?.docs ?? [];
                final now = DateTime.now();
                final overdue = docs
                    .where((doc) => crmIsFollowUpOverdue(doc.data(), now))
                    .length;
                return _buildInterestedCrmToolbar(
                  loc,
                  isAr,
                  overdueCount: overdue,
                );
              },
            ),
            const Divider(height: 1),
          ],

          // List
          Expanded(
            child: _current == AdminFilter.pending
                ? _buildPendingMergedList(loc, isAr)
                : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _stream(_current),
                    builder: (context, snap) =>
                        _buildStreamBody(context, loc, isAr, snap),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDealsSubTabs(AppLocalizations loc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _deals(),
        builder: (context, snap) {
          final allDocs = snap.data?.docs ?? [];
          final now = DateTime.now();
          final overdueCount = allDocs
              .where((doc) => _dealMatchesOverdueFilter(doc.data(), now))
              .length;

          Widget chip({
            required int tabIndex,
            required String label,
            required Color selectedColor,
            Color? unselectedLabelColor,
            Widget? labelChild,
            BorderSide? side,
          }) {
            final selected = _selectedTab == tabIndex;
            return Expanded(
              child: ChoiceChip(
                showCheckmark: false,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                label: labelChild ?? Center(child: Text(label)),
                selected: selected,
                onSelected: (_) => setState(() => _selectedTab = tabIndex),
                selectedColor: selectedColor,
                side: side,
                labelStyle: TextStyle(
                  color: selected
                      ? Colors.white
                      : (unselectedLabelColor ?? Colors.black87),
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              chip(
                tabIndex: 0,
                label: loc.adminDealsSubtabNew,
                selectedColor: _primaryBlue,
              ),
              const SizedBox(width: 8),
              chip(
                tabIndex: 1,
                label: loc.adminDealsSubtabInProgress,
                selectedColor: _primaryBlue,
              ),
              const SizedBox(width: 8),
              chip(
                tabIndex: 2,
                label: loc.adminDealsSubtabOverdue,
                selectedColor: Colors.red.shade700,
                unselectedLabelColor: overdueCount > 0
                    ? Colors.red.shade900
                    : Colors.black87,
                side: BorderSide(
                  color: overdueCount > 0 && _selectedTab != 2
                      ? Colors.red.shade300
                      : Colors.transparent,
                ),
                labelChild: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(loc.adminDealsSubtabOverdue),
                        if (overdueCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: _selectedTab == 2
                                  ? Colors.white.withValues(alpha: 0.28)
                                  : Colors.red.shade100,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$overdueCount',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: _selectedTab == 2
                                    ? Colors.white
                                    : Colors.red.shade900,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// كارد موحد في قيد المراجعة — نفس الشكل للإعلان والمطلوب، والمطلوب لا يُفتح بالضغط
  Widget _buildPendingMergedTile(
    AppLocalizations loc,
    _PendingMergedItem item,
  ) {
    final d = item.doc.data() as Map<String, dynamic>? ?? {};
    final createdAt = d['createdAt'] as Timestamp?;
    final typeEn = (d['type'] ?? '').toString();
    final area = (d['area'] ?? d['area_id'] ?? '-').toString();
    final typeLabel = _translateType(context, typeEn);
    final isProperty = item.type == 'property';
    final isValuation = item.type == 'valuation';

    String titleLine;
    String priceLine;
    String dateLine;
    Widget leftWidget;
    List<Widget> actionButtons = [];

    if (isProperty) {
      final cover = _coverFrom(d['coverUrl'], d['images']);
      final price = _fmtPrice(d['price']);
      final expiresAt = d['expiresAt'] as Timestamp?;
      titleLine = '$area • $typeLabel';
      priceLine = '${loc.price}: $price KWD';
      dateLine =
          '${loc.addedOn}: ${_fmtDate(createdAt)}\n${loc.expiresOn}: ${_fmtDate(expiresAt)}';
      leftWidget = _Thumb(url: cover);
      final approveKey = 'approve:${item.doc.id}';
      final rejectKey = 'reject:${item.doc.id}';
      actionButtons.addAll([
        TextButton.icon(
          onPressed: _isLoading(approveKey)
              ? null
              : () => _approveListing(item.doc.id),
          icon: _isLoading(approveKey)
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.verified),
          label: Text(loc.approve),
          style: TextButton.styleFrom(foregroundColor: _primaryBlue),
        ),
        TextButton.icon(
          onPressed: _isLoading(rejectKey)
              ? null
              : () => _rejectListing(item.doc.id),
          icon: _isLoading(rejectKey)
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.block),
          label: Text(loc.reject),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
        ),
      ]);
    } else if (isValuation) {
      final owner = (d['ownerName'] ?? '-').toString();
      final gov = (d['governorate'] ?? '-').toString();
      final pType = (d['propertyType'] ?? '-').toString();
      final pArea = (d['propertyArea'] ?? '-').toString();
      titleLine = '$owner • $gov - $area';
      priceLine =
          '${loc.valuation_propertyType}: $pType | ${loc.valuation_propertyArea}: $pArea';
      dateLine = '${loc.addedOn}: ${_fmtDate(createdAt)}';
      leftWidget = Container(
        width: 72,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.grey[200],
        ),
        child: const Icon(Icons.assessment, color: Colors.black45, size: 32),
      );
      actionButtons.addAll([
        TextButton.icon(
          onPressed: () => _approveValuation(item.doc.id),
          icon: const Icon(Icons.verified),
          label: Text(loc.approve),
          style: TextButton.styleFrom(foregroundColor: _primaryBlue),
        ),
        TextButton.icon(
          onPressed: () => _rejectValuation(item.doc.id),
          icon: const Icon(Icons.block),
          label: Text(loc.reject),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
        ),
      ]);
    } else {
      final minP = _fmtPrice(d['minPrice']);
      final maxP = _fmtPrice(d['maxPrice']);
      titleLine = '$area • $typeLabel';
      priceLine = '${loc.budget}: $minP - $maxP KWD';
      dateLine = '${loc.addedOn}: ${_fmtDate(createdAt)}';
      leftWidget = Container(
        width: 72,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.grey[200],
        ),
        child: const Icon(Icons.search, color: Colors.black45, size: 32),
      );
      actionButtons.addAll([
        TextButton.icon(
          onPressed: () => _approveWanted(item.doc.id),
          icon: const Icon(Icons.verified),
          label: Text(loc.approve),
          style: TextButton.styleFrom(foregroundColor: _primaryBlue),
        ),
        TextButton.icon(
          onPressed: () => _rejectWanted(item.doc.id),
          icon: const Icon(Icons.block),
          label: Text(loc.reject),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
        ),
      ]);
    }

    final card = Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            leftWidget,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    titleLine,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    priceLine,
                    style: const TextStyle(
                      fontSize: 15,
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(dateLine, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(mainAxisSize: MainAxisSize.min, children: actionButtons),
          ],
        ),
      ),
    );

    if (isProperty) {
      return GestureDetector(
        onTap: () {
          context.pushPropertyDetails(
            propertyId: item.doc.id,
            isAdminView: true,
          );
        },
        child: card,
      );
    }
    if (isValuation) {
      return GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ValuationDetailsPage(valuationId: item.doc.id),
            ),
          );
        },
        child: card,
      );
    }
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                WantedDetailsPage(wantedId: item.doc.id, isAdminView: true),
          ),
        );
      },
      child: card,
    );
  }

  Widget _buildPendingMergedList(AppLocalizations loc, bool isAr) {
    return StreamBuilder<List<_PendingMergedItem>>(
      stream: _pendingMergedStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                  const SizedBox(height: 12),
                  Text(snap.error.toString(), textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        }
        final items = snap.data ?? [];
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                textAlign: TextAlign.center,
                isAr
                    ? 'لا توجد إعلانات ولا طلبات مطلوب ولا طلبات تقييم قيد المراجعة'
                    : 'No pending listings, wanted requests, or valuation requests',
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) => _buildPendingMergedTile(loc, items[i]),
        );
      },
    );
  }

  Widget _buildStreamBody(
    BuildContext context,
    AppLocalizations loc,
    bool isAr,
    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snap,
  ) {
    if (snap.connectionState == ConnectionState.waiting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snap.hasError) {
      final err = snap.error.toString();
      final isNetwork =
          err.contains('unavailable') ||
          err.contains('network') ||
          err.contains('Failed to get');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
              const SizedBox(height: 12),
              Text(
                isAr ? 'خطأ في التحميل' : 'Load error',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                err,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
              if (isNetwork) ...[
                const SizedBox(height: 12),
                Text(
                  isAr
                      ? 'تحقق من الاتصال بالإنترنت وأعد فتح الصفحة'
                      : 'Check internet connection and reopen',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.orange[800]),
                ),
              ],
            ],
          ),
        ),
      );
    }
    var docs = snap.data?.docs ?? [];
    var interestedCountBeforeFilter = 0;
    if (_current == AdminFilter.collection) {
      docs = docs.where((doc) => !isPaid(doc.data())).toList();
    }
    if (_current == AdminFilter.deals) {
      final now = DateTime.now();
      docs = docs.where((doc) {
        final data = doc.data();
        final st = (data['dealStatus'] ?? '').toString().trim();
        if (_selectedTab == 0) {
          return st == DealStatus.newLead;
        }
        if (_selectedTab == 1) {
          return st != DealStatus.newLead &&
              st != DealStatus.closed &&
              st != DealStatus.notInterested;
        }
        if (_selectedTab == 2) {
          return _dealMatchesOverdueFilter(data, now);
        }
        return false;
      }).toList();
    }
    if (_current == AdminFilter.interested) {
      interestedCountBeforeFilter = docs.length;
      docs = _filterAndSortInterestedDocs(docs);
    }
    if (docs.isEmpty) {
      String emptyMsg;
      if (_current == AdminFilter.interested) {
        emptyMsg = interestedCountBeforeFilter > 0
            ? (isAr
                  ? 'لا توجد نتائج للتصفية الحالية'
                  : 'No leads match current filters')
            : (isAr ? 'لا يوجد مهتمون' : 'No interested leads');
      } else if (_current == AdminFilter.closureRequests) {
        emptyMsg = isAr
            ? 'لا توجد طلبات إغلاق معلّقة'
            : 'No pending closure requests';
      } else if (_current == AdminFilter.deals) {
        emptyMsg = switch (_selectedTab) {
          0 => (isAr ? 'لا توجد صفقات جديدة' : 'No new deals'),
          1 => (isAr ? 'لا توجد صفقات قيد المتابعة' : 'No deals in progress'),
          _ => (isAr ? 'لا توجد صفقات متأخرة' : 'No overdue follow-ups'),
        };
      } else if (_current == AdminFilter.collection) {
        emptyMsg = loc.adminDealsCollectionEmpty;
      } else if (_current == AdminFilter.wanted) {
        emptyMsg = isAr
            ? 'لا توجد طلبات مطلوب.\nإذا أضفت طلباً ولم يظهر، تحقق من الاتصال بالإنترنت وأعد المحاولة.'
            : 'No wanted requests.\nIf you added one and it\'s missing, check internet and try again.';
      } else if (_current == AdminFilter.support) {
        emptyMsg = loc.supportNoTickets;
      } else {
        emptyMsg = loc.noWantedItems;
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(textAlign: TextAlign.center, emptyMsg),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: docs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _buildItem(loc, _current, docs[i], isAr),
    );
  }

  Widget _badgePending(AppLocalizations loc) {
    final isSelected = _current == AdminFilter.pending;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final label = isAr ? 'قيد المراجعة' : 'Pending';

    return StreamBuilder<List<void>>(
      stream: _pendingCountStream(),
      builder: (ctx, snap) {
        final count = snap.data?.length ?? 0;
        return ChoiceChip(
          selected: isSelected,
          selectedColor: Colors.black87,
          onSelected: (_) => setState(() => _current = AdminFilter.pending),
          labelStyle: TextStyle(
            color: isSelected ? Colors.white : Colors.black,
          ),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white : Colors.black12,
                  borderRadius: BorderRadius.circular(50),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: isSelected ? Colors.black : Colors.black87,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _badge(
    String en,
    String ar,
    AdminFilter f,
    Stream<QuerySnapshot<Map<String, dynamic>>> stream, {
    int Function(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs)?
    docCount,
  }) {
    final isSelected = _current == f;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final label = isAr ? ar : en;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (ctx, snap) {
        final docs = snap.data?.docs ?? [];
        final count = docCount != null ? docCount(docs) : docs.length;

        return ChoiceChip(
          selected: isSelected,
          selectedColor: Colors.black87,
          onSelected: (_) => setState(() => _current = f),
          labelStyle: TextStyle(
            color: isSelected ? Colors.white : Colors.black,
          ),
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white : Colors.black12,
                  borderRadius: BorderRadius.circular(50),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    color: isSelected ? Colors.black : Colors.black87,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
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
