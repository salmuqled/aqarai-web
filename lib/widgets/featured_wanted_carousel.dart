import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:aqarai_app/services/firestore.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/pages/wanted_details_page.dart';

/// كاروسيل "مطلوب مميز" — يظهر في الهوم بيج وصفحة المطلوب
class FeaturedWantedCarousel extends StatelessWidget {
  /// عنوان مخصص إن لزم
  final String? title;
  /// true = خلفية داكنة (هوم) فالنص أبيض، false = خلفية فاتحة (صفحة مطلوب)
  final bool darkBackground;

  const FeaturedWantedCarousel({
    super.key,
    this.title,
    this.darkBackground = true,
  });

  Query<Map<String, dynamic>> _query() {
    final now = Timestamp.now();
    return firestore
        .collection('wanted_requests')
        .where('approved', isEqualTo: true)
        .where('featuredUntil', isGreaterThan: now)
        .orderBy('featuredUntil')
        .limit(20);
  }

  static String _typeLabel(String type, AppLocalizations loc) {
    switch (type) {
      case 'apartment': return loc.propertyType_apartment;
      case 'house': return loc.propertyType_house;
      case 'building': return loc.propertyType_building;
      case 'land': return loc.propertyType_land;
      case 'industrialLand': return loc.propertyType_industrialLand;
      case 'shop': return loc.propertyType_shop;
      case 'office': return loc.propertyType_office;
      case 'chalet': return loc.propertyType_chalet;
      default: return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final displayTitle = title ?? loc.featuredWanted;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _query().snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return SizedBox(
            height: 56,
            child: Center(child: Text('Error: ${snapshot.error}')),
          );
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12).copyWith(top: 12),
              child: Row(
                children: [
                  Icon(Icons.star, color: Colors.amber[700]),
                  const SizedBox(width: 6),
                  Text(
                    displayTitle,
                    style: TextStyle(
                      color: darkBackground ? Colors.white : Colors.grey[800],
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 160,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final d = doc.data();
                  final govRaw = (d['governorate'] ?? '').toString();
                  final areaRaw = (d['area'] ?? '').toString();
                  final gov = isAr ? govRaw : (governorateArToEn[govRaw] ?? govRaw);
                  final area = isAr ? areaRaw : (areaArToEn[areaRaw] ?? areaRaw);
                  final type = (d['propertyType'] ?? d['type'] ?? '').toString();
                  final typeLabel = _typeLabel(type, loc);
                  final min = d['minPrice'];
                  final max = d['maxPrice'];
                  final budgetStr = '${min ?? '-'} → ${max ?? '-'} ${isAr ? 'د.ك' : 'KWD'}';

                  return _FeaturedWantedCard(
                    title: '$gov • $area',
                    subtitle: typeLabel,
                    budgetText: budgetStr,
                    isAr: isAr,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => WantedDetailsPage(
                            wantedId: doc.id,
                            isAdminView: false,
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

class _FeaturedWantedCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String budgetText;
  final bool isAr;
  final VoidCallback? onTap;

  const _FeaturedWantedCard({
    required this.title,
    required this.subtitle,
    required this.budgetText,
    required this.isAr,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final badgeText = isAr ? 'مميز' : 'Featured';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 260,
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
                height: 90,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                  color: Colors.grey[200],
                ),
                child: Stack(
                  children: [
                    const Center(
                      child: Icon(Icons.search, size: 40, color: Colors.black38),
                    ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade600,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star, size: 14, color: Colors.white),
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
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[700],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        budgetText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: Colors.green,
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
