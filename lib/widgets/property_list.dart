import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../widgets/property_details_page.dart';
import 'package:aqarai_app/data/kuwait_areas.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/utils/property_area_display.dart';
import 'package:aqarai_app/utils/property_listing_cover.dart';
import 'package:aqarai_app/utils/property_price_display.dart';
import 'package:aqarai_app/widgets/listing_thumbnail_image.dart';

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
  });

  /// Same query as the list stream (including [orderBy] + [limit]) — for one-off reads (e.g. availability).
  static Query<Map<String, dynamic>> buildFirestoreQuery({
    required String governorateCode,
    required String areaCode,
    String? typeFilter,
    String? serviceType,
    String? rentalType,
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

    return query.orderBy('createdAt', descending: true).limit(100);
  }

  @override
  State<PropertyList> createState() => _PropertyListState();
}

class _PropertyListState extends State<PropertyList> {
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

        if (widget.allowedPropertyIds != null) {
          final allow = widget.allowedPropertyIds!;
          properties =
              properties.where((doc) => allow.contains(doc.id)).toList();
        }

        if (properties.isEmpty) {
          final filteredByAvailability = widget.allowedPropertyIds != null;
          return Center(
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
          );
        }

        return _propertyListCards(
          context: context,
          loc: loc,
          locale: locale,
          properties: properties,
        );
      },
    );
  }

  Widget _propertyListCards({
    required BuildContext context,
    required AppLocalizations loc,
    required String locale,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> properties,
  }) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: properties.length,
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
        final priceText = NumberFormat.decimalPattern(
          locale,
        ).format(price);
        final displayType = resolveDisplayPriceType(
          serviceType: data['serviceType']?.toString(),
          priceType: data['priceType']?.toString(),
        );
        final priceUnit = priceSuffix(
          displayType,
          locale.startsWith('ar'),
        );
        final num? priceNum = price is num ? price : num.tryParse('$price');
        final nh = widget.nightsForTotalHint;
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
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PropertyDetailsPage(
                  propertyId: doc.id,
                  leadSource: widget.leadSource,
                ),
              ),
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
                        Text(
                          'KWD $priceText$priceUnit',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.green[700],
                            height: 1.2,
                          ),
                        ),
                        if (displayType == DisplayPriceType.daily &&
                            nh != null &&
                            nh > 0 &&
                            priceNum != null &&
                            priceNum > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            locale == 'ar'
                                ? 'الإجمالي: ${NumberFormat.decimalPattern(locale).format(priceNum * nh)} د.ك'
                                : 'Total: ${NumberFormat.decimalPattern(locale).format(priceNum * nh)} KWD',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey[700],
                              height: 1.2,
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

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final body = _resultsStreamBody(_firestoreQuery());

    if (!widget.useScaffold) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(title: Text(loc.propertiesInArea(widget.areaLabel))),
      body: body,
    );
  }
}
