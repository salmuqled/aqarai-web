import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../widgets/property_details_page.dart';
import 'package:aqarai_app/data/kuwait_areas.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/utils/property_area_display.dart';
import 'package:aqarai_app/utils/property_listing_cover.dart';
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

class PropertyList extends StatelessWidget {
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

  const PropertyList({
    super.key,
    required this.governorateLabel,
    required this.areaLabel,
    required this.governorateCode,
    required this.areaCode,
    this.typeFilter,
    this.serviceType,
    this.leadSource = DealLeadSource.search,
  });

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;

    // ---------------------------------------------------
    // Marketplace queries: fixed base + optional chain
    // serviceType → type → governorateCode → areaCode → orderBy createdAt.
    // ---------------------------------------------------
    final bool chaletMode =
        governorateCode == 'chalet' || (typeFilter != null && typeFilter == 'chalet');

    Query query = FirebaseFirestore.instance.collection('properties');

    if (chaletMode) {
      query = query
          .where('approved', isEqualTo: true)
          .where('listingCategory', isEqualTo: ListingCategory.chalet)
          .where('hiddenFromPublic', isEqualTo: false);
      if (serviceType != null && serviceType!.isNotEmpty) {
        query = query.where('serviceType', isEqualTo: serviceType);
      }
      final typeForQuery = (typeFilter != null &&
              typeFilter!.isNotEmpty &&
              typeFilter != 'chalet')
          ? typeFilter
          : null;
      if (typeForQuery != null) {
        query = query.where('type', isEqualTo: typeForQuery);
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
      if (serviceType != null && serviceType!.isNotEmpty) {
        query = query.where('serviceType', isEqualTo: serviceType);
      }
      if (typeFilter != null && typeFilter!.isNotEmpty) {
        query = query.where('type', isEqualTo: typeFilter);
      }
      if (governorateCode.isNotEmpty && governorateCode != 'chalet') {
        query = query.where('governorateCode', isEqualTo: governorateCode);
      }
      if (areaCode.isNotEmpty) {
        query = query.where('areaCode', isEqualTo: areaCode);
      }
    }

    query = query.orderBy('createdAt', descending: true).limit(100);

    return Scaffold(
      appBar: AppBar(title: Text(loc.propertiesInArea(areaLabel))),
      body: StreamBuilder<QuerySnapshot>(
        stream: query.snapshots(),
        builder: (context, snapshot) {
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

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Text(
                loc.searchResultsForArea(areaLabel),
                style: const TextStyle(fontSize: 18),
              ),
            );
          }

          final properties = snapshot.data!.docs
              .where(
                (doc) => listingDataIsPubliclyDiscoverable(
                  doc.data() as Map<String, dynamic>,
                ),
              )
              .toList(); // defense-in-depth vs rules

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: properties.length,
            itemBuilder: (context, index) {
              final doc = properties[index];
              final data = doc.data() as Map<String, dynamic>;

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
              final fallbackArea = isValidAreaLabel(fallbackRaw)
                  ? fallbackRaw
                  : '';
              final areaName = areaNameFromCode.isNotEmpty
                  ? areaNameFromCode
                  : fallbackArea;
              final serviceRaw = (data['serviceType'] ?? '').toString();
              final serviceLabel = _serviceTypeLabel(loc, serviceRaw);
              final statusLabel = _statusBadgeLabel(loc, locale, data);
              final priceText = NumberFormat.decimalPattern(
                locale,
              ).format(price);
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
                        leadSource: leadSource,
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
                                'KWD $priceText',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green[700],
                                  height: 1.2,
                                ),
                              ),
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
        },
      ),
    );
  }
}
