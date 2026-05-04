// lib/services/conversational_search_service.dart
// Phase 1: تحليل رسالة المستخدم (عربي/إنجليزي) واستخراج فلاتر + أسئلة توضيحية + بناء استعلام Firestore

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/data/governorates_data_ar.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/chat_analytics_service.dart';

/// نتيجة تحليل رسالة البحث المحادثي
class ConversationalSearchResult {
  final ParsedFilters filters;
  final List<String> clarificationQuestions;
  final bool canRunQuery;

  const ConversationalSearchResult({
    required this.filters,
    required this.clarificationQuestions,
    required this.canRunQuery,
  });
}

/// فلاتر مستخرجة من النص أو من خريطة الـ Agent
///
/// Date Intelligence Layer contract (mirrors `functions/src/search_context.ts`):
/// - [startDate] is the inclusive check-in day (UTC midnight).
/// - [endDate] is the **exclusive** check-out day (hotel convention — same as
///   `chalet_booking_widget.dart` which calculates
///   `nights = endDate.difference(startDate).inDays`).
/// - [nights] is redundant with the two dates but carried alongside so any
///   downstream UI / logger doesn't have to recompute.
///
/// Safety invariant: either ALL THREE fields are present and self-consistent
/// (`endDate.isAfter(startDate) && nights >= 1`), or NONE of them are. Partial
/// date triples are rejected at parse time — see [parseFiltersFromMap].
class ParsedFilters {
  final String? areaCode;

  /// Multi-area selection. Populated when the customer named 2+ canonical
  /// `areaCode`s in one message ("الخيران بنيدر جليعه") OR the agent expanded
  /// a vague chalet request to the canonical chalet belt. When non-empty
  /// (length >= 2) the marketplace queries run a Firestore `whereIn` over
  /// these slugs and IGNORE [areaCode]. Each entry is canonical (lowercase
  /// underscored) and present in `kuwaitAreas` — never a fabricated joined
  /// slug. Firestore caps `whereIn` at 30 values so we always trim to 30.
  final List<String>? areaCodes;
  final String? governorateCode;
  final String? serviceType; // sale | rent
  final String? propertyType; // house, apartment, villa, chalet, ...

  /// Optional rental cadence — `daily`, `monthly`, or `full`. Distinguishes
  /// "شقة شهرية" vs "شقة يومية" when a user is explicit. Null means "no
  /// preference" (both branches included).
  final String? rentalType;
  final double? maxPrice;
  final int? bedrooms; // roomCount في Firestore

  /// Inclusive check-in day (UTC midnight). Null when the user has not yet
  /// provided a travel window in chat.
  final DateTime? startDate;

  /// Exclusive check-out day (UTC midnight), hotel convention.
  final DateTime? endDate;

  /// Whole nights between [startDate] and [endDate]. Always >= 1 when set.
  final int? nights;

  const ParsedFilters({
    this.areaCode,
    this.areaCodes,
    this.governorateCode,
    this.serviceType,
    this.propertyType,
    this.rentalType,
    this.maxPrice,
    this.bedrooms,
    this.startDate,
    this.endDate,
    this.nights,
  });

  /// True when a multi-area selection is active (>= 2 distinct slugs).
  bool get hasMultiArea => areaCodes != null && areaCodes!.length >= 2;

  bool get hasArea => hasMultiArea || (areaCode != null && areaCode!.isNotEmpty);

  /// True only when the full date triple is present AND consistent.
  bool get hasDateRange =>
      startDate != null &&
      endDate != null &&
      nights != null &&
      nights! >= 1 &&
      endDate!.isAfter(startDate!);
}

/// خدمة البحث المحادثي — تحليل محلي بدون Cloud Function
class ConversationalSearchService {
  static String _code(String s) {
    var v = s.trim().toLowerCase();
    v = v.replaceAll(RegExp(r'\s+'), '_');
    v = v.replaceAll('-', '_');
    v = v.replaceAll(RegExp(r'[^a-z0-9_]+'), '');
    v = v.replaceAll(RegExp(r'_+'), '_');
    v = v.replaceAll(RegExp(r'^_+|_+$'), '');
    return v;
  }

  static final Map<String, String> _areaNameToAreaCode = _buildAreaNameToCode();
  static final Map<String, String> _areaToGovernorateCode = _buildAreaToGovernorateCode();

  static Map<String, String> _buildAreaNameToCode() {
    final out = <String, String>{};
    for (final e in areaArToEn.entries) {
      final ar = e.key.trim().toLowerCase();
      final en = e.value.trim();
      final code = _code(en);
      if (code.isNotEmpty) {
        out[ar] = code;
        out[en.toLowerCase()] = code;
      }
    }
    return out;
  }

  /// areaCode أو اسم المنطقة (عربي/إنجليزي) -> governorateCode
  static Map<String, String> _buildAreaToGovernorateCode() {
    final out = <String, String>{};
    for (final e in governoratesAndAreasAr.entries) {
      final govAr = e.key;
      final govEn = governorateArToEn[govAr] ?? '';
      final govCode = _code(govEn);
      if (govCode.isEmpty) continue;
      for (final areaAr in e.value) {
        final areaEn = areaArToEn[areaAr] ?? areaAr;
        final areaCode = _code(areaEn);
        final areaArLower = areaAr.trim().toLowerCase();
        final areaEnLower = areaEn.trim().toLowerCase();
        if (areaCode.isNotEmpty) {
          out[areaCode] = govCode;
          out[areaArLower] = govCode;
          out[areaEnLower] = govCode;
        }
      }
    }
    return out;
  }

  // كلمات مفتاحية لنوع الخدمة
  static const List<String> _saleKeywordsAr = ['بيع', 'للبيع', 'شراء', 'ابي اشتري', 'أريد شراء'];
  static const List<String> _saleKeywordsEn = ['sale', 'buy', 'for sale', 'purchase'];
  static const List<String> _rentKeywordsAr = ['ايجار', 'إيجار', 'للإيجار', 'استأجر', 'ابي استأجر'];
  static const List<String> _rentKeywordsEn = ['rent', 'rental', 'lease', 'for rent'];

  // نوع العقار: قيمة Firestore <- كلمات عربي/إنجليزي
  // Keep these slugs aligned with the add-property form dropdown so we never
  // emit a type that can't actually exist on a listing (e.g. `warehouse`).
  // `villa` / `farm` / `room` are kept for conversational parsing — the
  // form doesn't offer them but customers type them often, and the backend
  // ranking tolerates an empty type filter downstream.
  static const Map<String, List<String>> _propertyTypeKeywords = {
    'house': ['house', 'بيت', 'منزل', 'دار'],
    'apartment': ['apartment', 'شقة', 'شقق', 'اپارتمان'],
    'villa': ['villa', 'فيلا', 'فلل'],
    'chalet': ['chalet', 'شاليه', 'شاليهات'],
    'shop': ['shop', 'محل', 'محلات', 'متجر'],
    'office': ['office', 'مكتب', 'مكاتب'],
    'land': ['land', 'أرض', 'اراضي'],
    'building': ['building', 'بناية', 'عمارة'],
    'farm': ['farm', 'مزرعة'],
    'room': ['room', 'غرفة', 'غرف'],
  };

  /// يحلل الرسالة ويرجع الفلاتر + أسئلة توضيحية
  ConversationalSearchResult parse(String userMessage) {
    final text = userMessage.trim();
    final lower = text.toLowerCase();
    String? areaCode;
    String? governorateCode;
    String? serviceType;
    String? propertyType;
    double? maxPrice;
    final clarificationQuestions = <String>[];

    // استخراج المنطقة (مطلوب للاستعلام)
    for (final e in _areaNameToAreaCode.entries) {
      if (lower.contains(e.key)) {
        areaCode = e.value;
        governorateCode = _areaToGovernorateCode[e.key] ?? _areaToGovernorateCode[e.value];
        break;
      }
    }
    if (areaCode == null || areaCode.isEmpty) {
      clarificationQuestions.add('في أي منطقة تبحث؟ (مثال: القادسية، النزهة، السالمية)');
    }

    // نوع الخدمة
    for (final k in _rentKeywordsAr) {
      if (lower.contains(k)) {
        serviceType = 'rent';
        break;
      }
    }
    if (serviceType == null) {
      for (final k in _rentKeywordsEn) {
        if (lower.contains(k)) {
          serviceType = 'rent';
          break;
        }
      }
    }
    if (serviceType == null) {
      for (final k in _saleKeywordsAr) {
        if (lower.contains(k)) {
          serviceType = 'sale';
          break;
        }
      }
    }
    if (serviceType == null) {
      for (final k in _saleKeywordsEn) {
        if (lower.contains(k)) {
          serviceType = 'sale';
          break;
        }
      }
    }

    // نوع العقار
    for (final e in _propertyTypeKeywords.entries) {
      for (final kw in e.value) {
        if (lower.contains(kw)) {
          propertyType = e.key;
          break;
        }
      }
      if (propertyType != null) break;
    }

    // أقصى سعر — أرقام مع د.ك، ك، ألف، مليون
    final priceReg = RegExp(r'(\d+(?:\.\d+)?)\s*(?:الف|ألف|الفا|ك|د\.ك|kd|kwd|thousand|مليون|million)?', caseSensitive: false);
    final priceMatch = priceReg.firstMatch(text);
    if (priceMatch != null) {
      var num = double.tryParse(priceMatch.group(1) ?? '') ?? 0;
      final rest = text.substring(priceMatch.end).trim().toLowerCase();
      if (rest.startsWith('مليون') || rest.startsWith('million') || text.contains('مليون') || text.contains('million')) {
        num *= 1000000;
      } else if (rest.startsWith('الف') || rest.startsWith('ألف') || rest.startsWith('ك') || rest.contains('الف') || rest.contains('thousand') || rest.contains('k ')) {
        num *= 1000;
      }
      if (num > 0) maxPrice = num;
    }

    final filters = ParsedFilters(
      areaCode: areaCode,
      governorateCode: governorateCode,
      serviceType: serviceType,
      propertyType: propertyType,
      maxPrice: maxPrice,
    );

    final canRunQuery = filters.hasArea;

    return ConversationalSearchResult(
      filters: filters,
      clarificationQuestions: clarificationQuestions,
      canRunQuery: canRunQuery,
    );
  }

  /// Fixed base + optional order: serviceType → type → governorateCode → areaCode → orderBy createdAt.
  Query<Map<String, dynamic>> _normalMarketplaceQuery(ParsedFilters f) {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection('properties')
        .where('approved', isEqualTo: true)
        .where('isActive', isEqualTo: true)
        .where('listingCategory', isEqualTo: ListingCategory.normal)
        .where('hiddenFromPublic', isEqualTo: false);
    if (f.serviceType != null && f.serviceType!.trim().isNotEmpty) {
      q = q.where('serviceType', isEqualTo: f.serviceType!.trim());
    }
    if (f.propertyType != null && f.propertyType!.trim().isNotEmpty) {
      q = q.where('type', isEqualTo: f.propertyType!.trim());
    }
    if (f.rentalType != null && f.rentalType!.trim().isNotEmpty) {
      q = q.where('rentalType', isEqualTo: f.rentalType!.trim());
    }
    if (f.governorateCode != null &&
        f.governorateCode!.trim().isNotEmpty &&
        f.governorateCode!.trim() != 'chalet') {
      q = q.where('governorateCode', isEqualTo: f.governorateCode!.trim());
    }
    final multi = _expandMultiAreaCodes(f);
    if (multi != null && multi.length >= 2) {
      q = q.where('areaCode', whereIn: multi);
    } else if (f.areaCode != null && f.areaCode!.trim().isNotEmpty) {
      final area = f.areaCode!.trim();
      final cluster = _areaCluster[area];
      if (cluster != null && cluster.length > 1) {
        q = q.where('areaCode', whereIn: cluster);
      } else {
        q = q.where('areaCode', isEqualTo: area);
      }
    }
    return q.orderBy('createdAt', descending: true);
  }

  /// Shared sibling-area cluster map for ALL marketplace search branches.
  ///
  /// Phase 1 generalization: an area cluster is the minimum set of canonical
  /// `areaCode` slugs that a customer treats as a single "place". Kuwaitis say
  /// "الخيران" to mean "the whole Khiran coastline" — which spans coastal
  /// `sabah_al_ahmad_marine_khiran` and inland `khiran_residential_inland`.
  /// Any slug inside a cluster broadens the query with Firestore `whereIn` so
  /// a customer never gets a false "no results" just because their listing
  /// happens to sit on the sibling slug.
  ///
  /// Scope guardrails:
  /// - Used by BOTH [_normalMarketplaceQuery] and [_chaletMarketplaceQuery].
  ///   When a cluster exists for the user's `areaCode`, every branch expands
  ///   to the cluster; otherwise strict equality applies (no change).
  /// - Firestore `whereIn` accepts up to 30 values; keep clusters small (≤ 10).
  /// - Add new clusters only when two or more slugs describe the same
  ///   colloquial place. Keep distinct areas distinct (e.g. salmiya and
  ///   hawalli are neighbors, not the same place).
  static const Map<String, List<String>> _areaCluster = {
    'sabah_al_ahmad_marine_khiran': [
      'sabah_al_ahmad_marine_khiran',
      'khiran_residential_inland',
      'khiran',
    ],
    'khiran_residential_inland': [
      'sabah_al_ahmad_marine_khiran',
      'khiran_residential_inland',
      'khiran',
    ],
    // Bare "khiran" slug (legacy chalet area in `kuwait_areas.dart`). When the
    // resolver lands on it — e.g. an older listing stamped with `khiran` only,
    // or a future code path that picks the standalone `AreaModel(code:
    // 'khiran')` — we still want the chat to show coastal AND inland Khiran
    // chalets, the same way customers think of "الخيران" in conversation.
    'khiran': [
      'khiran',
      'sabah_al_ahmad_marine_khiran',
      'khiran_residential_inland',
    ],
    // Defensive alias for the English-typo slug "khairan". Earlier server-side
    // smart_suggestions chips shipped this misspelling (we've since fixed the
    // chips, but historical chat transcripts and any caller that hardcoded
    // "khairan" still flow through here). Treating it as the same Khiran
    // cluster prevents the dead "ما نزل شي" path on a slug that has zero rows
    // in Firestore.
    'khairan': [
      'khiran',
      'sabah_al_ahmad_marine_khiran',
      'khiran_residential_inland',
    ],
  };

  Query<Map<String, dynamic>> _chaletMarketplaceQuery(ParsedFilters f) {
    // Intentionally NOT filtering by `isActive == true` here.
    //
    // The public chalet browse page (`PropertyList.buildFirestoreQuery`,
    // chalet branch) only requires `approved == true` and
    // `hiddenFromPublic == false`. Many existing chalet listings either
    // omit the `isActive` field or store it as `true` only after a manual
    // re-save. Adding `where('isActive', '==', true)` here used to make
    // the AI chat return ZERO chalets in areas where the regular search
    // had several visible — exactly the divergence customers reported.
    // Lifecycle gating is still applied later by
    // `listingDataIsPubliclyDiscoverable` once we have the document.
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection('properties')
        .where('approved', isEqualTo: true)
        .where('hiddenFromPublic', isEqualTo: false);
    if (f.serviceType != null && f.serviceType!.trim().isNotEmpty) {
      q = q.where('serviceType', isEqualTo: f.serviceType!.trim());
    }
    // Phase 1: no chalet-type default. When the user didn't specify a type,
    // let this branch match whatever lives in the chalet marketplace bucket
    // (typically chalets, but also hybrid chalet listings). Type-aware
    // clarification happens BEFORE search when we truly have nothing to go on
    // (see `aqaraiAgentAnalyze`'s hard guard on missing areaCode).
    if (f.propertyType != null && f.propertyType!.trim().isNotEmpty) {
      q = q.where('type', isEqualTo: f.propertyType!.trim());
    }
    if (f.rentalType != null && f.rentalType!.trim().isNotEmpty) {
      q = q.where('rentalType', isEqualTo: f.rentalType!.trim());
    }
    if (f.governorateCode != null &&
        f.governorateCode!.trim().isNotEmpty &&
        f.governorateCode!.trim() != 'chalet') {
      q = q.where('governorateCode', isEqualTo: f.governorateCode!.trim());
    }
    final multi = _expandMultiAreaCodes(f);
    if (multi != null && multi.length >= 2) {
      q = q.where('areaCode', whereIn: multi);
    } else if (f.areaCode != null && f.areaCode!.trim().isNotEmpty) {
      final area = f.areaCode!.trim();
      final cluster = _areaCluster[area];
      if (cluster != null && cluster.length > 1) {
        q = q.where('areaCode', whereIn: cluster);
      } else {
        q = q.where('areaCode', isEqualTo: area);
      }
    }
    return q.orderBy('createdAt', descending: true);
  }

  /// Expand a multi-area selection into the final list passed to Firestore
  /// `whereIn`.
  ///
  /// Behavior:
  ///   1. Returns `null` when `f.areaCodes` is missing / shorter than 2 — the
  ///      caller falls back to single-area logic.
  ///   2. For every entry, expand through [_areaCluster] so a customer who
  ///      typed "الخيران" (single canonical slug) still pulls coastal +
  ///      inland Khiran inventory inside a multi-area whereIn — the same
  ///      promise the single-area path makes.
  ///   3. Deduplicates and trims to Firestore's 30-value `whereIn` cap. We
  ///      drop overflow rather than splitting the query: the customer-facing
  ///      surface area is the chalet belt (~9 codes after expansion), so 30
  ///      is safely larger than realistic inputs.
  List<String>? _expandMultiAreaCodes(ParsedFilters f) {
    if (f.areaCodes == null || f.areaCodes!.length < 2) return null;
    final out = <String>{};
    for (final raw in f.areaCodes!) {
      final code = raw.trim().toLowerCase();
      if (code.isEmpty) continue;
      final cluster = _areaCluster[code];
      if (cluster != null && cluster.isNotEmpty) {
        out.addAll(cluster);
      } else {
        out.add(code);
      }
    }
    if (out.length < 2) return null;
    final list = out.toList();
    if (list.length > 30) {
      return list.sublist(0, 30);
    }
    return list;
  }

  /// No `whereIn` on listingCategory: two branches merged in memory.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> fetchMarketplaceMerged(
    ParsedFilters filters, {
    int limitPerCategory = 60,
    bool applyAvailabilityGate = true,
  }) async {
    final n = await _normalMarketplaceQuery(filters).limit(limitPerCategory).get();
    final c = await _chaletMarketplaceQuery(filters).limit(limitPerCategory).get();
    final byId = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final d in n.docs) {
      byId[d.id] = d;
    }
    for (final d in c.docs) {
      byId[d.id] = d;
    }
    var list = byId.values
        .where((d) => listingDataIsPubliclyDiscoverable(d.data()))
        .toList();

    // Availability gate (AI chat). Only applies to date-based rental queries:
    //   - `filters.hasDateRange` must be true (Date Intelligence Layer triple).
    //   - `filters.serviceType == "rent"`.
    // Within the result set, we further narrow to listings that are actually
    // date-bookable (`type == 'chalet'` OR `rentalType == 'daily'`). Listings
    // that don't match those rules (monthly rentals, sales) are passed through
    // untouched — they have no booking calendar so availability has no meaning
    // for them. This preserves pre-existing behavior for all non-daily flows.
    //
    // `applyAvailabilityGate: false` lets the Smart Suggestions pipeline fetch
    // the *pre-gate* candidate pool so it can probe shifted windows against
    // actual data (see assistant_page → `_fetchSmartSuggestions`).
    if (applyAvailabilityGate) {
      list = await _applyChatAvailabilityGate(list, filters);
    }

    int ms(Timestamp? t) => t?.millisecondsSinceEpoch ?? 0;
    list.sort((a, b) => ms(b.data()['createdAt'] as Timestamp?).compareTo(
          ms(a.data()['createdAt'] as Timestamp?),
        ));

    // Analytics: only emit `search_executed` / `search_empty` for gated
    // (user-facing) searches. Pre-gate fetches driven by the Smart Suggestions
    // engine (`applyAvailabilityGate: false`) are internal probes and would
    // otherwise double-count every search.
    if (applyAvailabilityGate) {
      _logSearchEvents(filters: filters, resultCount: list.length);
    }
    return list;
  }

  /// Emits `search_executed` for every gated search, plus `search_empty` when
  /// the result set is empty. Fully fire-and-forget — never awaited, never
  /// throws.
  void _logSearchEvents({
    required ParsedFilters filters,
    required int resultCount,
  }) {
    try {
      final filtersPayload = <String, dynamic>{
        if (filters.serviceType != null) 'serviceType': filters.serviceType,
        if (filters.propertyType != null) 'propertyType': filters.propertyType,
        if (filters.areaCode != null) 'areaCode': filters.areaCode,
        if (filters.areaCodes != null && filters.areaCodes!.length >= 2)
          'areaCodes': filters.areaCodes,
        if (filters.governorateCode != null)
          'governorateCode': filters.governorateCode,
        if (filters.maxPrice != null) 'maxPrice': filters.maxPrice,
        if (filters.bedrooms != null) 'bedrooms': filters.bedrooms,
        if (filters.nights != null) 'nights': filters.nights,
      };
      final svc = (filters.serviceType ?? '').trim().toLowerCase();

      ChatAnalyticsService().logEvent(
        ChatAnalyticsEvents.searchExecuted,
        <String, dynamic>{
          'resultCount': resultCount,
          'filters': filtersPayload,
          'hasDateRange': filters.hasDateRange,
          'serviceType': svc.isEmpty ? null : svc,
        },
      );
      if (resultCount == 0) {
        ChatAnalyticsService().logEvent(
          ChatAnalyticsEvents.searchEmpty,
          <String, dynamic>{
            'filters': filtersPayload,
            'hasDateRange': filters.hasDateRange,
          },
        );
      }
    } catch (_) {
      // never propagate analytics failures to the search path
    }
  }

  /// Returns true when a listing document must pass the chat availability gate
  /// (i.e. it's a date-bookable daily unit). Monthly rentals and sales short-
  /// circuit and keep their current behavior.
  static bool _isDateBookableDoc(Map<String, dynamic> d) {
    final type = (d['type']?.toString() ?? '').trim().toLowerCase();
    final rentalType = (d['rentalType']?.toString() ?? '').trim().toLowerCase();
    return type == 'chalet' || rentalType == 'daily';
  }

  /// Calls the `filterChatAvailability` Cloud Function for the date-bookable
  /// subset of [list] and returns a filtered list that only keeps:
  ///   - non-date-bookable docs (sales, monthly rentals), unchanged, AND
  ///   - date-bookable docs whose IDs are in the `allowedPropertyIds` response.
  ///
  /// The gate is a no-op when [filters] has no date range or is not a rental
  /// query. All errors are swallowed (returns the input list unchanged) so a
  /// transient availability-service outage cannot silently blank the chat.
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _applyChatAvailabilityGate(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> list,
    ParsedFilters filters,
  ) async {
    if (list.isEmpty) return list;
    if (!filters.hasDateRange) return list;
    final svc = (filters.serviceType ?? '').trim().toLowerCase();
    if (svc != 'rent') return list;

    final candidates = <String>[];
    for (final d in list) {
      if (_isDateBookableDoc(d.data())) candidates.add(d.id);
    }
    if (candidates.isEmpty) return list;

    try {
      final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
      final callable = functions.httpsCallable('filterChatAvailability');
      final result = await callable.call(<String, dynamic>{
        'propertyIds': candidates,
        'startDate': filters.startDate!.toUtc().toIso8601String(),
        'endDate': filters.endDate!.toUtc().toIso8601String(),
      });
      final data = result.data;
      final raw = (data is Map && data['allowedPropertyIds'] is List)
          ? (data['allowedPropertyIds'] as List)
          : const <dynamic>[];
      final allowed = <String>{
        for (final x in raw)
          if (x is String && x.isNotEmpty) x,
      };
      return list
          .where((d) => !_isDateBookableDoc(d.data()) || allowed.contains(d.id))
          .toList();
    } catch (err) {
      // Fail-open: on availability service outage, surface listings as-is
      // rather than break the entire chat result set. The booking form itself
      // is the final authoritative gate (`checkBookingAvailability`).
      if (kDebugMode) {
        debugPrint('chat_availability_gate_error: $err');
      }
      return list;
    }
  }

  /// Nearby: sequential area scans (no `whereIn` on areaCode).
  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> fetchNearbyMarketplaceMerged(
    ParsedFilters baseFilters,
    List<String> nearbyAreaCodes, {
    int maxAreas = 10,
    int limitPerAreaBranch = 24,
  }) async {
    if (nearbyAreaCodes.isEmpty) return [];
    final codes = nearbyAreaCodes.length > maxAreas
        ? nearbyAreaCodes.sublist(0, maxAreas)
        : nearbyAreaCodes;
    final byId = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final code in codes) {
      final pf = ParsedFilters(
        areaCode: code,
        governorateCode: baseFilters.governorateCode,
        serviceType: baseFilters.serviceType,
        propertyType: baseFilters.propertyType,
        rentalType: baseFilters.rentalType,
        maxPrice: baseFilters.maxPrice,
        bedrooms: baseFilters.bedrooms,
        startDate: baseFilters.startDate,
        endDate: baseFilters.endDate,
        nights: baseFilters.nights,
      );
      final part = await fetchMarketplaceMerged(pf, limitPerCategory: limitPerAreaBranch);
      for (final d in part) {
        byId[d.id] = d;
      }
      if (byId.length >= 80) break;
    }
    final list = byId.values.toList();
    int ms(Timestamp? t) => t?.millisecondsSinceEpoch ?? 0;
    list.sort((a, b) => ms(b.data()['createdAt'] as Timestamp?).compareTo(
          ms(a.data()['createdAt'] as Timestamp?),
        ));
    return list;
  }

  /// تطابق الوثيقة مع فلاتر المحادثة (بعد الجلب من Firestore).
  bool documentMatchesConversationFilters(
    Map<String, dynamic> data,
    Map<String, dynamic> filters,
  ) {
    final governorateCode = filters['governorateCode']?.toString().trim() ?? '';
    if (governorateCode.isNotEmpty && governorateCode != 'chalet') {
      if ((data['governorateCode']?.toString() ?? '') != governorateCode) {
        return false;
      }
    }
    final serviceType = filters['serviceType']?.toString().trim() ?? '';
    if (serviceType.isNotEmpty) {
      if ((data['serviceType']?.toString() ?? '') != serviceType) return false;
    }
    final type = filters['type']?.toString().trim() ?? '';
    if (type.isNotEmpty) {
      if ((data['type']?.toString() ?? '') != type) return false;
    }
    final rentalType =
        filters['rentalType']?.toString().trim().toLowerCase() ?? '';
    if (rentalType == 'daily' ||
        rentalType == 'monthly' ||
        rentalType == 'full') {
      if ((data['rentalType']?.toString().trim().toLowerCase() ?? '') !=
          rentalType) {
        return false;
      }
    }
    final bedrooms = filters['bedrooms'];
    final br = bedrooms is int
        ? bedrooms
        : (bedrooms != null ? int.tryParse(bedrooms.toString()) : null);
    if (br != null && br > 0) {
      final rc = data['roomCount'];
      final n = rc is int ? rc : int.tryParse(rc?.toString() ?? '') ?? -1;
      if (n != br) return false;
    }
    if (!listingDataIsPubliclyDiscoverable(data)) return false;
    return true;
  }

  /// Parses Agent / UI filter map into [ParsedFilters].
  ParsedFilters parseFiltersFromMap(Map<String, dynamic> filters) {
    final areaCode = filters['areaCode']?.toString().trim();
    // Multi-area: the agent surfaces `areaCodes` (List<String>) when the
    // customer named 2+ areas in one message OR when the orchestrator
    // expanded a vague chalet request to the canonical chalet belt. We
    // accept both `List<String>` and `List<dynamic>` (Functions JSON
    // round-trips can wrap entries as `dynamic`); we coerce to a clean
    // `List<String>` and dedupe. A list of length < 2 is dropped — single-
    // area runs through `areaCode` so the cluster-aware single-area path
    // (which expands "الخيران" siblings) still kicks in.
    final rawAreaCodes = filters['areaCodes'];
    List<String>? areaCodes;
    if (rawAreaCodes is List) {
      final cleaned = rawAreaCodes
          .map((v) => v?.toString().trim().toLowerCase() ?? '')
          .where((v) => v.isNotEmpty)
          .toSet()
          .toList();
      if (cleaned.length >= 2) areaCodes = cleaned;
    }
    final type = filters['type']?.toString().trim();
    final serviceType = filters['serviceType']?.toString().trim();
    final rawRentalType =
        filters['rentalType']?.toString().trim().toLowerCase();
    // Only accept the canonical values actually stored on listings.
    // Everything else (including empty) is coerced back to null so we don't
    // accidentally query with a garbage value.
    final rentalType = (rawRentalType == 'daily' ||
            rawRentalType == 'monthly' ||
            rawRentalType == 'full')
        ? rawRentalType
        : null;
    final budget = filters['budget'] is num
        ? (filters['budget'] as num).toDouble()
        : (filters['budget'] != null
              ? double.tryParse(filters['budget'].toString())
              : null);
    final bedrooms = filters['bedrooms'] is int
        ? filters['bedrooms'] as int
        : (filters['bedrooms'] != null
              ? int.tryParse(filters['bedrooms'].toString())
              : null);
    final governorateCode = filters['governorateCode']?.toString().trim();

    final dateTriple = _parseDateTriple(filters);

    return ParsedFilters(
      areaCode: areaCode?.isNotEmpty == true ? areaCode : null,
      areaCodes: areaCodes,
      governorateCode: governorateCode?.isNotEmpty == true ? governorateCode : null,
      serviceType: serviceType?.isNotEmpty == true ? serviceType : null,
      propertyType: type?.isNotEmpty == true ? type : null,
      rentalType: rentalType,
      maxPrice: budget != null && budget > 0 ? budget : null,
      bedrooms: bedrooms != null && bedrooms > 0 ? bedrooms : null,
      startDate: dateTriple?.startDate,
      endDate: dateTriple?.endDate,
      nights: dateTriple?.nights,
    );
  }

  /// Defensive parser for the `startDate / endDate / nights` triple coming from
  /// either the Agent (`params_patch`) or persisted `_currentFilters` on the
  /// client. Returns null unless BOTH dates parse successfully AND the derived
  /// night count falls within a sane [1..365] window. Partial triples are
  /// rejected (no assumption) — this mirrors the backend contract defined in
  /// `functions/src/context_updater.ts`.
  static _DateTriple? _parseDateTriple(Map<String, dynamic> filters) {
    final start = _coerceIsoDate(filters['startDate']);
    final end = _coerceIsoDate(filters['endDate']);
    if (start == null || end == null) return null;
    if (!end.isAfter(start)) return null;
    final diff = end.difference(start).inDays;
    if (diff < 1 || diff > 365) return null;
    final rawNights = filters['nights'];
    int nights = diff;
    if (rawNights is int && rawNights > 0) {
      nights = rawNights;
    } else if (rawNights is num && rawNights > 0) {
      nights = rawNights.round();
    } else if (rawNights is String && rawNights.trim().isNotEmpty) {
      nights = int.tryParse(rawNights.trim()) ?? diff;
    }
    if (nights <= 0) nights = diff;
    return _DateTriple(startDate: start, endDate: end, nights: nights);
  }

  /// Coerces an arbitrary value into a UTC `DateTime`. Handles:
  ///   - ISO-8601 strings (wire format used by `functions/src/search_context.ts`)
  ///   - millis (num)
  ///   - `DateTime`
  ///   - Firestore `Timestamp`
  /// Returns null on anything else.
  static DateTime? _coerceIsoDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    if (v is Timestamp) return v.toDate().toUtc();
    if (v is num) {
      if (!v.isFinite) return null;
      return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
    }
    if (v is String) {
      final s = v.trim();
      if (s.isEmpty) return null;
      return DateTime.tryParse(s)?.toUtc();
    }
    return null;
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> fetchMarketplaceMergedFromMap(
    Map<String, dynamic> filters, {
    int limitPerCategory = 60,
    bool applyAvailabilityGate = true,
  }) =>
      fetchMarketplaceMerged(
        parseFiltersFromMap(filters),
        limitPerCategory: limitPerCategory,
        applyAvailabilityGate: applyAvailabilityGate,
      );

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> fetchNearbyMarketplaceMergedFromMap(
    Map<String, dynamic> filters,
    List<String> nearbyAreaCodes,
  ) =>
      fetchNearbyMarketplaceMerged(parseFiltersFromMap(filters), nearbyAreaCodes);
}

/// Internal plain-old-data carrier for the validated date triple. Never
/// exposed publicly — consumers use [ParsedFilters.startDate/endDate/nights].
class _DateTriple {
  final DateTime startDate;
  final DateTime endDate;
  final int nights;
  const _DateTriple({
    required this.startDate,
    required this.endDate,
    required this.nights,
  });
}
