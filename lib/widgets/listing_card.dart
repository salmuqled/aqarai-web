// lib/widgets/listing_card.dart

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';

/// Badge text for labels (Arabic). Max 2 shown.
const Map<String, String> _labelBadgeAr = {
  'new_listing': '🆕 إعلان جديد',
  'high_demand': '🔥 طلب عالي',
  'good_deal': '⭐ فرصة جيدة',
};

const Map<String, String> _labelBadgeEn = {
  'new_listing': '🆕 New listing',
  'high_demand': '🔥 High demand',
  'good_deal': '⭐ Good deal',
};

class ListingCard extends StatelessWidget {
  final String id;
  final Map<String, dynamic> data;
  /// Optional intelligence labels from backend (e.g. new_listing, high_demand, good_deal). Max 2 displayed.
  final List<String>? labels;
  /// When provided, card is tappable and opens details (e.g. PropertyDetailsPage).
  final VoidCallback? onTap;

  const ListingCard({
    super.key,
    required this.id,
    required this.data,
    this.labels,
    this.onTap,
  });

  /// Resolve labels from widget or data, map to badge text, max 2.
  List<String> _effectiveLabels(bool isArabic) {
    final raw = labels ?? (data['labels'] is List ? (data['labels'] as List).map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList() : <String>[]);
    final map = isArabic ? _labelBadgeAr : _labelBadgeEn;
    return raw.take(2).map((id) => map[id] ?? id).where((s) => s.isNotEmpty).toList();
  }

  // ---------------------- تنسيق السعر ----------------------
  String _fmtPrice(num? p, String locale) {
    if (p == null) return '-';
    return NumberFormat.decimalPattern(locale).format(p);
  }

  // ---------------------- استخراج صورة الغلاف ----------------------
  String? _coverFrom(dynamic images, dynamic coverUrl) {
    final cf = coverUrl?.toString();
    if (cf != null && cf.isNotEmpty) return cf;

    if (images is List && images.isNotEmpty) {
      final first = images.first?.toString();
      if (first != null && first.isNotEmpty) return first;
    }

    if (images is Map && images.isNotEmpty) {
      for (final v in images.values) {
        final s = v?.toString();
        if (s != null && s.isNotEmpty) return s;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final localeStr = Localizations.localeOf(context).toString();

    final cover = _coverFrom(data['images'], data['coverUrl']);
    final price = data['price'];
    final area = (data['area'] ?? data['areaAr'] ?? data['areaEn'] ?? data['area_id'] ?? data['areaCode'] ?? '').toString();
    final type = (data['type'] ?? '').toString().toLowerCase();

    // ---------------------- ترجمة الأنواع ----------------------
    const Map<String, String> propertyTypeAr = {
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

    final typeText = isArabic ? (propertyTypeAr[type] ?? type) : type;

    return GestureDetector(
      onTap: onTap,
      child: Container(
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------------------- صورة العقار ----------------------
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14),
              ),
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: cover != null
                    ? CachedNetworkImage(
                        imageUrl: cover,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey[200]),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey[300]),
                      )
                    : Container(
                        height: 180,
                        color: Colors.grey[300],
                        child: const Icon(
                          Icons.image,
                          size: 40,
                          color: Colors.black38,
                        ),
                      ),
              ),
            ),

            // ---------------------- تفاصيل النص ----------------------
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_effectiveLabels(isArabic).isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: _effectiveLabels(isArabic)
                          .map((text) => Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  text,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.amber[800],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Text(
                        typeText,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      const SizedBox(width: 6),
                      const Text("•"),
                      const SizedBox(width: 6),

                      Expanded(
                        child: Text(
                          area,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  Text(
                    isArabic
                        ? "السعر: ${_fmtPrice(price, localeStr)} د.ك"
                        : "Price: ${_fmtPrice(price, localeStr)} KWD",
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
