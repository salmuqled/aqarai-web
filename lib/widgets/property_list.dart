import 'dart:ui' as ui;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import 'package:aqarai_app/app/property_route.dart';
import 'package:aqarai_app/data/kuwait_areas.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/utils/listing_display.dart';
import 'package:aqarai_app/utils/property_area_display.dart';
import 'package:aqarai_app/utils/property_listing_cover.dart';
import 'package:aqarai_app/utils/property_price_display.dart';
import 'package:aqarai_app/widgets/listing_thumbnail_image.dart';
import 'package:aqarai_app/widgets/stay_dates_picker.dart';

bool isValidAreaLabel(String? value) {
  if (value == null) return false;

  final v = value.trim().toLowerCase();

  return v.isNotEmpty &&
      v != '-' &&
      v != '—' &&
      v != '–' &&
      v != '−' &&
      v != 'n/a' &&
      v != 'null';
}

class PropertyList extends StatefulWidget {
  // النصوص الظاهرة للمستخدم
  final String governorateLabel;
  final String areaLabel;

  // 🔥 codes الجديدة للبحث (الأساس الدائم)
  final String governorateCode;
  final String areaCode;

  // فلتر النوع
  final String? typeFilter;

  // فلتر نوع الخدمة
  final String? serviceType;

  /// Passed through to property details (search results list).
  final String leadSource;

  /// Optional: when set with daily [priceType], show total (price × nights) under list price.
  final int? nightsForTotalHint;

  /// When non-null and non-empty, adds Firestore `rentalType` equality filter.
  /// Parent is the only source of truth; no in-widget rental type selection.
  final String? rentalType;

  /// When `false`, omits [Scaffold] and [AppBar] so this widget can live inside another page.
  final bool useScaffold;

  /// When non-null, only documents whose id is in this set are shown (after discoverability).
  final Set<String>? allowedPropertyIds;

  /// Optional, chalet-only: a pre-normalized (trimmed + lowercased) prefix
  /// applied to the Firestore `chaletNameLower` field as a range query.
  /// Empty / null means "no name filter" — the existing behavior is unchanged.
  final String? chaletNameQuery;

  /// Optional, chalet-only: a pre-normalized (Arabic-aware) prefix applied to
  /// the Firestore `chaletNameSearch` field as a range query. Empty / null
  /// means "no name filter". When BOTH this and [chaletNameQuery] are
  /// provided, this one wins (it's the strictly-more-forgiving path).
  ///
  /// Must be produced with [normalizeArabic] so the query side of the range
  /// matches the save side byte-for-byte; see [search_box.dart].
  final String? chaletNameSearchQuery;

  const PropertyList({
    super.key,
    required this.governorateLabel,
    required this.areaLabel,
    required this.governorateCode,
    required this.areaCode,
    this.typeFilter,
    this.serviceType,
    this.leadSource = DealLeadSource.search,
    this.nightsForTotalHint,
    this.rentalType,
    this.useScaffold = true,
    this.allowedPropertyIds,
    this.chaletNameQuery,
    this.chaletNameSearchQuery,
  });

  /// Same query as the list stream (including [orderBy] + [limit]) — for one-off reads (e.g. availability).
  static Query<Map<String, dynamic>> buildFirestoreQuery({
    required String governorateCode,
    required String areaCode,
    String? typeFilter,
    String? serviceType,
    String? rentalType,
    String? chaletNameQuery,
    String? chaletNameSearchQuery,
  }) {
    final bool chaletMode =
        governorateCode == 'chalet' ||
        (typeFilter != null && typeFilter == 'chalet');

    Query<Map<String, dynamic>> query =
        FirebaseFirestore.instance.collection('properties');

    if (chaletMode) {
      query = query
          .where('approved', isEqualTo: true)
          .where('hiddenFromPublic', isEqualTo: false);
      if (serviceType != null && serviceType.isNotEmpty) {
        query = query.where('serviceType', isEqualTo: serviceType);
      }
      final typeForQuery = (typeFilter != null &&
              typeFilter.isNotEmpty &&
              typeFilter != 'chalet')
          ? typeFilter
          : null;
      if (typeForQuery != null) {
        query = query.where('type', isEqualTo: typeForQuery);
      } else {
        query = query.where('type', isEqualTo: 'chalet');
      }
      if (governorateCode.isNotEmpty && governorateCode != 'chalet') {
        query = query.where('governorateCode', isEqualTo: governorateCode);
      }
      if (areaCode.isNotEmpty) {
        query = query.where('areaCode', isEqualTo: areaCode);
      }
    } else {
      query = query
          .where('approved', isEqualTo: true)
          .where('isActive', isEqualTo: true)
          .where('listingCategory', isEqualTo: ListingCategory.normal)
          .where('hiddenFromPublic', isEqualTo: false);
      if (serviceType != null && serviceType.isNotEmpty) {
        query = query.where('serviceType', isEqualTo: serviceType);
      }
      if (typeFilter != null && typeFilter.isNotEmpty) {
        query = query.where('type', isEqualTo: typeFilter);
      }
      if (governorateCode.isNotEmpty && governorateCode != 'chalet') {
        query = query.where('governorateCode', isEqualTo: governorateCode);
      }
      if (areaCode.isNotEmpty) {
        query = query.where('areaCode', isEqualTo: areaCode);
      }
    }

    if (rentalType != null && rentalType.isNotEmpty) {
      query = query.where('rentalType', isEqualTo: rentalType);
    }

    // Optional chalet-name prefix search. Firestore requires the first
    // [orderBy] to be on the same field as a range filter, so we sort by
    // the searched field first, then fall back to `createdAt desc` so within
    // a given prefix window users still see the newest matching chalets
    // first (expected UX). These queries need composite indexes
    // (search-field asc + `createdAt` desc, plus the active equality
    // filters); Firestore surfaces a one-click creation link the first time
    // each query runs. Listings without the search field are naturally
    // excluded from name-search results, which matches the spec.
    //
    // Priority: the Arabic-normalized `chaletNameSearch` path (more forgiving
    // — collapses أ/إ/آ / ؤ / ئ / ة / tashkeel) wins when present. The legacy
    // lowercase-only `chaletNameLower` path is preserved intact for callers
    // that haven't migrated.
    final String? nameSearchPrefix = chaletNameSearchQuery?.trim();
    if (nameSearchPrefix != null && nameSearchPrefix.isNotEmpty) {
      return query
          .where('chaletNameSearch', isGreaterThanOrEqualTo: nameSearchPrefix)
          .where('chaletNameSearch',
              isLessThanOrEqualTo: '$nameSearchPrefix\uf8ff')
          .orderBy('chaletNameSearch')
          .orderBy('createdAt', descending: true)
          .limit(100);
    }

    final String? namePrefix = chaletNameQuery?.trim();
    if (namePrefix != null && namePrefix.isNotEmpty) {
      return query
          .where('chaletNameLower', isGreaterThanOrEqualTo: namePrefix)
          .where('chaletNameLower',
              isLessThanOrEqualTo: '$namePrefix\uf8ff')
          .orderBy('chaletNameLower')
          .orderBy('createdAt', descending: true)
          .limit(100);
    }

    return query.orderBy('createdAt', descending: true).limit(100);
  }

  @override
  State<PropertyList> createState() => _PropertyListState();
}

class _PropertyListState extends State<PropertyList> {
  // --- Stay-dates availability filter (chalet + rent only). -----------------

  /// Hard-ceiling: stop paginating `searchDailyProperties` after this many
  /// property IDs so we don't spin on abnormally large result sets. Matches
  /// the existing Firestore `.limit(100)` budget with a safety buffer.
  static const int _availabilityIdCeiling = 200;

  /// Max pages of `searchDailyProperties` we'll walk to collect available ids.
  static const int _availabilityMaxPages = 15;

  DateTime? _stayStart;
  DateTime? _stayEnd;

  /// When non-null, only property IDs in this set survive client-side
  /// filtering — computed from [searchDailyProperties] when the user runs an
  /// availability search. `null` means "no availability filter active".
  Set<String>? _availabilityAllowedIds;

  int _availabilitySearchToken = 0;
  bool _availabilitySearching = false;
  String? _availabilityErrorMessage;

  /// Transparency flag: set when the Cloud Function walk hit
  /// [_availabilityIdCeiling] / [_availabilityMaxPages], meaning some
  /// available chalets may exist beyond what we fetched. UI-only hint.
  bool _availabilityMayBeTruncated = false;

  /// Page-level condition: picker + availability filtering are only enabled
  /// for "chalet + rent + daily" filters. This gate drives three things:
  ///
  ///   1. Whether [StayDatesPicker] is rendered at all.
  ///   2. Whether [_runAvailabilitySearch] (→ `searchDailyProperties`) can
  ///      fire — the callback is simply not wired when the picker is hidden.
  ///   3. Whether the banner + truncation hint are shown in the stream body.
  ///
  /// Monthly / yearly flows (`rentalType != 'daily'`) therefore render the
  /// plain Firestore list with ZERO side-channel calls, ZERO nights math, and
  /// ZERO availability filtering — matching the existing behavior for those
  /// rental modes.
  ///
  /// Does NOT inspect individual items. Also treats the "chalet" governorate
  /// shortcut as implicit `type=chalet` to match [buildFirestoreQuery].
  bool get _isChaletRentMode {
    final typeIsChalet =
        widget.typeFilter == 'chalet' || widget.governorateCode == 'chalet';
    final rt = widget.rentalType?.trim();
    final isDaily = rt == 'daily';
    return typeIsChalet && widget.serviceType == 'rent' && isDaily;
  }

  /// Effective allow-set used by the Firestore stream renderer. Combines any
  /// parent-provided `allowedPropertyIds` with the picker's availability set
  /// via intersection — the strictest filter wins.
  Set<String>? get _effectiveAllowedIds {
    final parent = widget.allowedPropertyIds;
    final local = _availabilityAllowedIds;
    if (parent == null) return local;
    if (local == null) return parent;
    return parent.intersection(local);
  }

  int? get _stayNights {
    final s = _stayStart;
    final e = _stayEnd;
    if (s == null || e == null) return null;
    final a = DateTime(s.year, s.month, s.day);
    final b = DateTime(e.year, e.month, e.day);
    final n = b.difference(a).inDays;
    return n > 0 ? n : null;
  }

  /// Nights derived from the in-page picker, ONLY when this page is in
  /// chalet + rent + daily mode. Monthly/yearly and non-chalet flows never
  /// reach this branch — see [_isChaletRentMode]. Returns null when dates
  /// aren't selected or the range is non-positive.
  int? get _pickerNights {
    if (!_isChaletRentMode) return null;
    return _stayNights;
  }

  Future<void> _runAvailabilitySearch(DateTime start, DateTime end) async {
    final token = ++_availabilitySearchToken;
    setState(() {
      _stayStart = start;
      _stayEnd = end;
      _availabilitySearching = true;
      _availabilityErrorMessage = null;
      _availabilityMayBeTruncated = false;
    });

    try {
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('searchDailyProperties');

      // Calendar-day UTC bounds match the contract enforced by daily_rent_page
      // and the Cloud Function itself.
      final startUtc = DateTime.utc(start.year, start.month, start.day);
      final endUtc =
          DateTime.utc(end.year, end.month, end.day, 23, 59, 59, 999);

      final collected = <String>{};
      String? cursor;
      bool hasMore = true;
      int page = 0;

      while (hasMore &&
          page < _availabilityMaxPages &&
          collected.length < _availabilityIdCeiling) {
        final payload = <String, dynamic>{
          'rentalType': 'daily',
          'startDate': startUtc.toIso8601String(),
          'endDate': endUtc.toIso8601String(),
          if (cursor != null) 'cursor': cursor,
        };

        final raw = await callable.call(payload);
        if (!mounted || token != _availabilitySearchToken) return;

        final data = raw.data;
        if (data is! Map) {
          throw Exception('Invalid searchDailyProperties response');
        }
        final m = Map<String, dynamic>.from(data);
        if (m['success'] != true) {
          throw Exception('searchDailyProperties was not successful');
        }

        final rawList = m['properties'];
        if (rawList is List) {
          for (final item in rawList) {
            if (item is Map) {
              final id = item['id'] ?? item['propertyId'] ?? item['uid'];
              if (id is String && id.isNotEmpty) {
                collected.add(id);
                if (collected.length >= _availabilityIdCeiling) break;
              }
            }
          }
        }

        final next = m['nextCursor'];
        hasMore = m['hasMore'] == true &&
            next is String &&
            next.isNotEmpty;
        cursor = hasMore ? next : null;
        page++;
      }

      if (!mounted || token != _availabilitySearchToken) return;
      // Mark as potentially truncated if we hit either the id ceiling or the
      // page ceiling while the backend still had more pages to serve.
      final truncated = collected.length >= _availabilityIdCeiling ||
          (page >= _availabilityMaxPages && hasMore);
      setState(() {
        _availabilityAllowedIds = collected;
        _availabilitySearching = false;
        _availabilityMayBeTruncated = truncated;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted || token != _availabilitySearchToken) return;
      setState(() {
        _availabilitySearching = false;
        _availabilityErrorMessage = e.message ?? e.code;
      });
    } catch (_) {
      if (!mounted || token != _availabilitySearchToken) return;
      setState(() {
        _availabilitySearching = false;
        _availabilityErrorMessage = 'Could not check availability.';
      });
    }
  }

  void _clearAvailability() {
    _availabilitySearchToken++;
    setState(() {
      _stayStart = null;
      _stayEnd = null;
      _availabilityAllowedIds = null;
      _availabilitySearching = false;
      _availabilityErrorMessage = null;
      _availabilityMayBeTruncated = false;
    });
  }

  String _serviceTypeLabel(AppLocalizations loc, String raw) {
    switch (raw.toLowerCase().trim()) {
      case 'sale':
        return loc.forSale;
      case 'rent':
        return loc.forRent;
      case 'exchange':
        return loc.forExchange;
      default:
        return raw;
    }
  }

  String _statusBadgeLabel(
    AppLocalizations loc,
    String locale,
    Map<String, dynamic> data,
  ) {
    return listingStatusChipLabel(data, locale);
  }

  Query<Map<String, dynamic>> _firestoreQuery() {
    final bool chaletMode =
        widget.governorateCode == 'chalet' ||
        (widget.typeFilter != null && widget.typeFilter == 'chalet');

    final String? rt = widget.rentalType?.trim();
    final String? rentalTypeFromParent =
        (rt != null && rt.isNotEmpty) ? rt : null;

    if (kDebugMode) {
      debugPrint(
        '[PropertyList] serviceType=${widget.serviceType} typeFilter=${widget.typeFilter} '
        'governorateCode=${widget.governorateCode} areaCode=${widget.areaCode} '
        'rentalType=$rentalTypeFromParent',
      );
      debugPrint(
        chaletMode
            ? '[PropertyList] QUERY MODE = CHALET'
            : '[PropertyList] QUERY MODE = NORMAL',
      );
    }

    return PropertyList.buildFirestoreQuery(
      governorateCode: widget.governorateCode,
      areaCode: widget.areaCode,
      typeFilter: widget.typeFilter,
      serviceType: widget.serviceType,
      rentalType: rentalTypeFromParent,
      chaletNameQuery: widget.chaletNameQuery,
      chaletNameSearchQuery: widget.chaletNameSearchQuery,
    );
  }

  Widget _resultsStreamBody(Query<Map<String, dynamic>> query) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        final loc = AppLocalizations.of(context)!;
        final locale = Localizations.localeOf(context).languageCode;

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${snapshot.error}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 14),
              ),
            ),
          );
        }

        if (kDebugMode && snapshot.hasData && snapshot.data != null) {
          final snapDocs = snapshot.data!.docs;
          debugPrint('[PropertyList snapshot] docCount=${snapDocs.length}');
          for (final doc in snapDocs) {
            final d = doc.data();
            final visible = listingDataIsPubliclyDiscoverable(d);
            debugPrint(
              '[PropertyList snapshot] id=${doc.id} approved=${d['approved']} '
              'serviceType=${d['serviceType']} type=${d['type']} '
              'listingCategory=${d['listingCategory']} governorateCode=${d['governorateCode']} '
              'areaCode=${d['areaCode']} | VISIBLE=$visible',
            );
          }
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Text(
              loc.searchResultsForArea(widget.areaLabel),
              style: const TextStyle(fontSize: 18),
            ),
          );
        }

        var properties = snapshot.data!.docs
            .where(
              (doc) => listingDataIsPubliclyDiscoverable(
                doc.data(),
              ),
            )
            .toList(); // defense-in-depth vs rules

        final effectiveAllow = _effectiveAllowedIds;
        if (effectiveAllow != null) {
          properties =
              properties.where((doc) => effectiveAllow.contains(doc.id)).toList();
        }

        if (properties.isEmpty) {
          final filteredByAvailability = effectiveAllow != null;
          return _wrapStreamResult(
            context,
            filteredCount: 0,
            content: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  filteredByAvailability
                      ? (locale == 'ar'
                          ? 'لا توجد عقارات متاحة في هذه الفترة.'
                          : 'No properties available for these dates.')
                      : loc.searchResultsForArea(widget.areaLabel),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            ),
          );
        }

        return _wrapStreamResult(
          context,
          filteredCount: properties.length,
          content: _propertyListCards(
            context: context,
            loc: loc,
            locale: locale,
            properties: properties,
          ),
        );
      },
    );
  }

  /// Wraps the filtered stream [content] with the availability banner + the
  /// optional "top results" truncation hint, so the banner count always
  /// reflects what the user actually sees (post-intersection).
  Widget _wrapStreamResult(
    BuildContext context, {
    required int filteredCount,
    required Widget content,
  }) {
    final banner = _buildAvailabilityBanner(context, filteredCount);
    final hint = _buildTruncationHint(context);
    final hasBanner = banner is! SizedBox;
    final hasHint = hint is! SizedBox;
    if (!hasBanner && !hasHint) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        banner,
        hint,
        Expanded(child: content),
      ],
    );
  }

  Widget _buildTruncationHint(BuildContext context) {
    if (!_availabilityMayBeTruncated) return const SizedBox.shrink();
    final locale = Localizations.localeOf(context).languageCode;
    final isAr = locale == 'ar';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              isAr
                  ? 'عرض أفضل النتائج المتاحة'
                  : 'Showing top available results',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _propertyListCards({
    required BuildContext context,
    required AppLocalizations loc,
    required String locale,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> properties,
  }) {
    // PERF — hoist the locale-aware number formatter out of the item
    // builder so we don't re-instantiate ICU rules for every card on
    // every scroll/build.
    final numberFmt = NumberFormat.decimalPattern(locale);
    final isArLocale = locale == 'ar';
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: properties.length,
      // Larger cache window so the next few cards are ready before they
      // enter the viewport during fast scrolling.
      cacheExtent: 600,
      // Cards are pure / stateless — keep-alives would just pin memory
      // without any benefit.
      addAutomaticKeepAlives: false,
      itemBuilder: (context, index) {
        final doc = properties[index];
        final data = doc.data();

        final price = data['price'] ?? 0;

        final String typeEn = data['type'] ?? '';
        late String typeLabel;

        if (locale == 'ar') {
          switch (typeEn.toLowerCase()) {
            case 'apartment':
              typeLabel = loc.propertyType_apartment;
              break;
            case 'house':
              typeLabel = loc.propertyType_house;
              break;
            case 'building':
              typeLabel = loc.propertyType_building;
              break;
            case 'land':
              typeLabel = loc.propertyType_land;
              break;
            case 'industrialland':
              typeLabel = loc.propertyType_industrialLand;
              break;
            case 'shop':
              typeLabel = loc.propertyType_shop;
              break;
            case 'office':
              typeLabel = loc.propertyType_office;
              break;
            case 'chalet':
              typeLabel = loc.propertyType_chalet;
              break;
            default:
              typeLabel = typeEn;
          }
        } else {
          typeLabel = typeEn;
        }

        final imageUrl = PropertyListingCover.urlFrom(data);

        final rawCode = data['areaCode'] ?? data['area_id'];
        final String? areaCode = rawCode == null
            ? null
            : rawCode.toString().trim().isEmpty
            ? null
            : rawCode.toString().trim();
        final areaNameFromCode = getKuwaitAreaName(areaCode, locale);
        final fallbackRaw = areaDisplayNameForProperty(data, locale);
        final fallbackArea = isValidAreaLabel(fallbackRaw) ? fallbackRaw : '';
        final areaName = areaNameFromCode.isNotEmpty
            ? areaNameFromCode
            : fallbackArea;
        final serviceRaw = (data['serviceType'] ?? '').toString();
        final serviceLabel = _serviceTypeLabel(loc, serviceRaw);
        final statusLabel = _statusBadgeLabel(loc, locale, data);
        final chaletName = listingChaletName(data);
        final priceText = numberFmt.format(price);
        final displayType = resolveDisplayPriceType(
          serviceType: data['serviceType']?.toString(),
          priceType: data['priceType']?.toString(),
        );
        final priceUnit = priceSuffix(
          displayType,
          locale.startsWith('ar'),
        );
        final num? priceNum = price is num ? price : num.tryParse('$price');
        // Nights for the "total" line. Picker-selected dates take priority
        // when active (chalet + rent + daily mode); otherwise we fall back to
        // any nights hint the parent may have supplied. Monthly/yearly and
        // unset states yield `null`, which the gate below treats as "hide".
        final int? nh = _pickerNights ?? widget.nightsForTotalHint;
        // Total row is visible only when ALL conditions hold — this is the
        // single source of truth for the booking-style price hierarchy.
        final bool totalVisible = displayType == DisplayPriceType.daily &&
            nh != null &&
            nh > 0 &&
            priceNum != null &&
            priceNum > 0;
        // "Best for short stays" chip — page-level gate (chalet + rent +
        // daily) AND per-item daily pricing. Does not depend on dates being
        // selected.
        final bool chipVisible =
            _isChaletRentMode && displayType == DisplayPriceType.daily;
        const spacing = 8.0;

        final isRtl = Directionality.of(context) == ui.TextDirection.rtl;
        final imageRadius = BorderRadius.only(
          topLeft: isRtl ? const Radius.circular(12) : Radius.zero,
          bottomLeft: isRtl ? const Radius.circular(12) : Radius.zero,
          topRight: isRtl ? Radius.zero : const Radius.circular(12),
          bottomRight: isRtl ? Radius.zero : const Radius.circular(12),
        );

        return GestureDetector(
          onTap: () {
            // Forward the in-page stay selection + rental filter so the
            // details page can pre-seed its chalet picker and show the
            // "Book Now" CTA immediately (only for daily chalet rentals).
            // Non-chalet / non-daily flows still pass null dates — the
            // details page falls back to its previous behavior.
            context.pushPropertyDetails(
              propertyId: doc.id,
              leadSource: widget.leadSource,
              stayStart: _isChaletRentMode ? _stayStart : null,
              stayEnd: _isChaletRentMode ? _stayEnd : null,
              rentalType: widget.rentalType,
            );
          },
          child: Card(
            margin: const EdgeInsets.only(bottom: 20),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: 0.12),
            surfaceTintColor: Colors.transparent,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // When the owner provided a custom chalet name, show
                        // it as a bold primary title with the old
                        // "type • area" line demoted to a small subtitle.
                        // Otherwise render the historical single-line
                        // "type • area" RichText exactly as before so
                        // non-named listings are pixel-identical.
                        if (chaletName.isNotEmpty) ...[
                          Text(
                            chaletName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                              height: 1.2,
                            ),
                          ),
                          if (typeLabel.isNotEmpty || areaName.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              areaName.isNotEmpty
                                  ? '$areaName • $typeLabel'
                                  : typeLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Colors.grey[600],
                                height: 1.2,
                              ),
                            ),
                          ],
                        ] else
                          RichText(
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            text: TextSpan(
                              style: DefaultTextStyle.of(
                                context,
                              ).style.copyWith(height: 1.25),
                              children: [
                                TextSpan(
                                  text: typeLabel,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black,
                                  ),
                                ),
                                if (areaName.isNotEmpty) ...[
                                  const TextSpan(
                                    text: ' • ',
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                  TextSpan(
                                    text: areaName,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        const SizedBox(height: spacing),
                        // Per-night line. When the TOTAL row is also visible,
                        // this line steps down in weight/size/color so the
                        // total stands out (booking-app hierarchy). When only
                        // the per-night line is shown, it keeps its original
                        // prominence — nothing changes for monthly / yearly /
                        // sale cards.
                        Text(
                          totalVisible
                              ? (locale == 'ar'
                                  ? '$priceText د.ك لكل ليلة'
                                  : 'KWD $priceText per night')
                              : 'KWD $priceText$priceUnit',
                          style: totalVisible
                              ? TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.green[600],
                                  height: 1.2,
                                )
                              : TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green[700],
                                  height: 1.2,
                                ),
                        ),
                        if (totalVisible) ...[
                          const SizedBox(height: 6),
                          Builder(
                            builder: (context) {
                              final totalText = numberFmt.format(priceNum * nh);
                              final nightsText = numberFmt.format(nh);
                              final line = isArLocale
                                  ? '$totalText د.ك إجمالي ($nightsText ${nh == 1 ? 'ليلة' : 'ليالي'})'
                                  : 'KWD $totalText total ($nightsText ${nh == 1 ? 'night' : 'nights'})';
                              return Text(
                                line,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.green[800],
                                  height: 1.2,
                                ),
                              );
                            },
                          ),
                        ],
                        if (chipVisible) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.green.withValues(alpha: 0.22),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              locale == 'ar'
                                  ? 'مناسب للإيجار القصير'
                                  : 'Best for short stays',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.green[800],
                                height: 1.1,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: spacing),
                        Text(
                          serviceLabel,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[600],
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: spacing),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            statusLabel,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[800],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (imageUrl != null)
                  ListingThumbnailImage(
                    imageUrl: imageUrl.toString(),
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                    borderRadius: imageRadius,
                  )
                else
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8E8E8),
                      borderRadius: imageRadius,
                    ),
                    child: Icon(
                      Icons.home_outlined,
                      size: 40,
                      color: Colors.grey[500],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAvailabilityBanner(BuildContext context, int filteredCount) {
    final locale = Localizations.localeOf(context).languageCode;
    final isAr = locale == 'ar';
    final scheme = Theme.of(context).colorScheme;

    if (_availabilityErrorMessage != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Material(
          color: scheme.errorContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 18, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _availabilityErrorMessage!,
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final start = _stayStart;
    final end = _stayEnd;
    final ids = _availabilityAllowedIds;
    if (start == null || end == null || ids == null) {
      return const SizedBox.shrink();
    }

    final fmt = DateFormat('dd/MM');
    final range = '${fmt.format(start)} → ${fmt.format(end)}';
    final nights = _stayNights ?? 0;

    // Count reflects the list actually rendered to the user (post
    // area/governorate intersection + discoverability filter), not the raw
    // CF-returned ID set — so banner + list always agree.
    final count = filteredCount;
    final label = isAr
        ? '$count ${count == 1 ? 'شاليه متاح' : 'شاليهات متاحة'} من $range · $nights ${nights == 1 ? 'ليلة' : 'ليالٍ'}'
        : '$count chalet${count == 1 ? '' : 's'} available from $range · $nights night${nights == 1 ? '' : 's'}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.event_available_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final streamBody = _resultsStreamBody(_firestoreQuery());

    Widget body = streamBody;
    if (_isChaletRentMode) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: StayDatesPicker(
              initialStartDate: _stayStart,
              initialEndDate: _stayEnd,
              isSearching: _availabilitySearching,
              onSearch: _runAvailabilitySearch,
              onClear: _clearAvailability,
            ),
          ),
          // Availability banner + truncation hint are rendered inside
          // `_resultsStreamBody` so the count reflects the actually-visible
          // (post-intersection) list length.
          Expanded(child: streamBody),
        ],
      );
    }

    if (!widget.useScaffold) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(title: Text(loc.propertiesInArea(widget.areaLabel))),
      body: body,
    );
  }
}
