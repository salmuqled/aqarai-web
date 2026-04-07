import 'package:flutter/material.dart';

import '../widgets/search_box_chalet.dart';
import '../widgets/featured_carousel.dart';
import '../l10n/app_localizations.dart';
import 'package:aqarai_app/models/listing_enums.dart';

class ChaletsPage extends StatelessWidget {
  const ChaletsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;

    return Scaffold(
      body: Stack(
        children: [
          // -------------------- الخلفية --------------------
          Positioned.fill(
            child: Image.asset(
              'assets/images/kuwait_bridge_bg.png',
              fit: BoxFit.cover,
            ),
          ),

          // -------------------- طبقة التعتيم --------------------
          Container(color: const Color(0xAA0B0F1A)),

          // -------------------- المحتوى --------------------
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 60),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),

                  // ------------------ زر الرجوع ------------------
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(
                          Icons.arrow_back_ios,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),

                  // ------------------ عنوان الصفحة ------------------
                  Center(
                    child: Text(
                      loc.chalets,
                      style: const TextStyle(
                        fontSize: 26,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ------------------ SearchBox Chalet ------------------
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SearchBoxChalet(),
                  ),

                  const SizedBox(height: 28),

                  // =====================================================
                  // ⭐ شاليهات مميزة للبيع
                  // =====================================================
                  FeaturedCarousel(
                    serviceType: 'sale',
                    title: locale == 'ar'
                        ? "شاليهات مميزة للبيع"
                        : "Featured Chalets for Sale",
                    listingCategory: ListingCategory.chalet,
                  ),

                  const SizedBox(height: 32),

                  // =====================================================
                  // ⭐ شاليهات مميزة للإيجار
                  // =====================================================
                  FeaturedCarousel(
                    serviceType: 'rent',
                    title: locale == 'ar'
                        ? "شاليهات مميزة للإيجار"
                        : "Featured Chalets for Rent",
                    listingCategory: ListingCategory.chalet,
                  ),

                  const SizedBox(height: 60),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
