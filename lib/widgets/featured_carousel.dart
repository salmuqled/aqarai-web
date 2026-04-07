import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:aqarai_app/services/firestore.dart';
import 'package:aqarai_app/widgets/property_details_page.dart';
import 'package:aqarai_app/models/listing_enums.dart';

class FeaturedCarousel extends StatelessWidget {
  final String serviceType;
  final String title;
  /// [ListingCategory.normal] or [ListingCategory.chalet] — drives visibility query (no status).
  final String listingCategory;

  const FeaturedCarousel({
    super.key,
    required this.serviceType,
    required this.title,
    required this.listingCategory,
  });

  String _normalizeType(dynamic raw) {
    if (raw == null) return '';
    final value = raw.toString().trim().toLowerCase();

    switch (value) {
      case 'شاليه':
      case 'شاليهات':
      case 'chalet':
      case 'chalets':
        return 'chalet';
      case 'بيت':
      case 'house':
        return 'house';
      case 'شقة':
      case 'apartment':
        return 'apartment';
      case 'فيلا':
      case 'villa':
        return 'villa';
      case 'مكتب':
      case 'office':
        return 'office';
      case 'محل':
      case 'shop':
        return 'shop';
      case 'مخزن':
      case 'warehouse':
        return 'warehouse';
      case 'أرض':
      case 'ارض':
      case 'land':
        return 'land';
      case 'مزرعة':
      case 'farm':
        return 'farm';
      case 'غرفة':
      case 'room':
        return 'room';
      default:
        return value;
    }
  }

  static const Map<String, String> propertyTypeAr = {
    'house': 'بيت',
    'apartment': 'شقة',
    'villa': 'فيلا',
    'shop': 'محل',
    'office': 'مكتب',
    'warehouse': 'مخزن',
    'land': 'أرض',
    'farm': 'مزرعة',
    'room': 'غرفة',
    'chalet': 'شاليه',
  };

  Query<Map<String, dynamic>> _query() {
    final now = Timestamp.now();

    Query<Map<String, dynamic>> query = firestore
        .collection('properties')
        .where('approved', isEqualTo: true);

    if (listingCategory == ListingCategory.normal) {
      query = query.where('isActive', isEqualTo: true);
    }

    query = query
        .where('listingCategory', isEqualTo: listingCategory)
        .where('hiddenFromPublic', isEqualTo: false)
        .where('serviceType', isEqualTo: serviceType)
        .where('featuredUntil', isGreaterThan: now);

    return query
        .orderBy('featuredUntil')
        .orderBy('createdAt', descending: true)
        .limit(40);
  }

  String _fmtPrice(num? price, String locale) {
    if (price == null) return '-';
    return NumberFormat.decimalPattern(locale).format(price);
  }

  String? _coverFrom(dynamic images, dynamic coverUrl) {
    final cover = coverUrl?.toString();
    if (cover != null && cover.isNotEmpty) return cover;

    if (images is List && images.isNotEmpty) {
      final first = images.first?.toString();
      if (first != null && first.isNotEmpty) return first;
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final localeStr = Localizations.localeOf(context).toString();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _query().snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 190,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return SizedBox(
            height: 56,
            child: Center(child: Text('Error: ${snapshot.error}')),
          );
        }

        final docs = (snapshot.data?.docs ?? [])
            .where((d) => listingDataIsPubliclyDiscoverable(d.data()))
            .toList();
        if (docs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
              ).copyWith(top: 12),
              child: Row(
                children: [
                  const Icon(Icons.star, color: Colors.amber),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 190,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final data = doc.data();

                  final coverUrl = _coverFrom(data['images'], data['coverUrl']);
                  final normalizedType = _normalizeType(data['type']);

                  String displayType = normalizedType;
                  if (isArabic) {
                    displayType =
                        propertyTypeAr[normalizedType] ?? normalizedType;
                  }

                  final area = isArabic
                      ? (data['areaAr'] ?? '').toString()
                      : (data['areaEn'] ?? '').toString();

                  final combinedTitle = area.isNotEmpty
                      ? '$displayType • $area'
                      : displayType;

                  final price = (data['price'] is num)
                      ? data['price'] as num
                      : num.tryParse('${data['price']}');

                  final priceText = isArabic
                      ? 'السعر: ${_fmtPrice(price, localeStr)} د.ك'
                      : 'Price: ${_fmtPrice(price, localeStr)} KWD';

                  return _FeaturedCard(
                    title: combinedTitle,
                    priceText: priceText,
                    coverUrl: coverUrl,
                    isArabic: isArabic,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              PropertyDetailsPage(
                                propertyId: doc.id,
                                leadSource: DealLeadSource.featured,
                              ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FeaturedCard extends StatelessWidget {
  final String title;
  final String priceText;
  final String? coverUrl;
  final bool isArabic;
  final VoidCallback? onTap;

  const _FeaturedCard({
    required this.title,
    required this.priceText,
    required this.isArabic,
    this.coverUrl,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final badgeText = isArabic ? 'مميز' : 'Featured';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 280,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.black12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            children: [
              Container(
                height: 120,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(14),
                  ),
                  image: (coverUrl != null && coverUrl!.isNotEmpty)
                      ? DecorationImage(
                          image: CachedNetworkImageProvider(coverUrl!),
                          fit: BoxFit.cover,
                        )
                      : null,
                  color: Colors.grey[200],
                ),
                child: Stack(
                  children: [
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade600,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.star,
                              size: 14,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              badgeText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        priceText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
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
