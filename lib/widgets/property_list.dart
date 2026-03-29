import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../l10n/app_localizations.dart';
import '../widgets/property_details_page.dart';
import 'package:aqarai_app/models/listing_enums.dart';

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
    // 🔥 بناء الـ Query (بحث احترافي ثابت)
    // ---------------------------------------------------
    // approved=true يكفي — المرفوضة لديها approved=false، نتجنب status لعدم الحاجة لـ index
    Query query = FirebaseFirestore.instance
        .collection('properties')
        .where('approved', isEqualTo: true);

    // فلتر النوع
    if (typeFilter != null && typeFilter!.isNotEmpty) {
      query = query.where('type', isEqualTo: typeFilter);
    }

    // فلتر المحافظة بالـ Code
    // ⚠️ لا نفلتر بـ governorateCode عندما يكون 'chalet' لأن العقارات المخزنة
    // تحمل المحافظة الفعلية (مثل ahmadi_governorate) وليس 'chalet'
    if (governorateCode.isNotEmpty && governorateCode != 'chalet') {
      query = query.where('governorateCode', isEqualTo: governorateCode);
    }

    // فلتر المنطقة بالـ Code
    if (areaCode.isNotEmpty) {
      query = query.where('areaCode', isEqualTo: areaCode);
    }

    // فلتر نوع الخدمة
    if (serviceType != null && serviceType!.isNotEmpty) {
      query = query.where('serviceType', isEqualTo: serviceType);
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
              .where((doc) =>
                  listingDataIsPubliclyDiscoverable(doc.data() as Map<String, dynamic>))
              .toList();

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

              final List<dynamic>? images = data['images'];
              final imageUrl = (images != null && images.isNotEmpty)
                  ? images.first
                  : null;

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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 3,
                  child: Row(
                    children: [
                      if (imageUrl != null)
                        ClipRRect(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            bottomLeft: Radius.circular(12),
                          ),
                          child: Image.network(
                            imageUrl,
                            width: 120,
                            height: 120,
                            fit: BoxFit.cover,
                          ),
                        )
                      else
                        Container(
                          width: 120,
                          height: 120,
                          decoration: const BoxDecoration(
                            color: Color(0xFFE0E0E0),
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(12),
                              bottomLeft: Radius.circular(12),
                            ),
                          ),
                          child: const Icon(Icons.home, size: 40),
                        ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                typeLabel,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'KWD $price',
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                areaLabel,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ],
                          ),
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
