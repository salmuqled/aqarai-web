import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../widgets/listing_card.dart';
import '../widgets/property_details_page.dart';
import '../l10n/app_localizations.dart';
import 'package:aqarai_app/models/listing_enums.dart';

class SearchResultsChaletPage extends StatelessWidget {
  final String? area;
  final String? serviceType; // sale / rent / exchange

  const SearchResultsChaletPage({super.key, this.area, this.serviceType});

  // -----------------------------
  // Firestore Query
  // -----------------------------
  Query<Map<String, dynamic>> _buildQuery() {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection('properties')
        .where('approved', isEqualTo: true)
        .where('status', isEqualTo: 'active')
        .where('type', isEqualTo: 'chalet'); // 🔥 فقط الشاليهات

    if (area != null && area!.isNotEmpty) {
      q = q.where('area', isEqualTo: area);
    }

    if (serviceType != null && serviceType!.isNotEmpty) {
      q = q.where('serviceType', isEqualTo: serviceType);
    }

    return q.orderBy('createdAt', descending: true).limit(100);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          loc.searchResults, // 🔥 "نتائج البحث"
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),

      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _buildQuery().snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snap.hasData || snap.data!.docs.isEmpty) {
            return Center(
              child: Text(
                loc.noWantedItems, // "لا توجد نتائج"
                style: const TextStyle(fontSize: 17, color: Colors.black54),
              ),
            );
          }

          final docs = snap.data!.docs
              .where((d) => listingDataIsPubliclyDiscoverable(d.data()))
              .toList();

          if (docs.isEmpty) {
            return Center(
              child: Text(
                loc.noWantedItems,
                style: const TextStyle(fontSize: 17, color: Colors.black54),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (_, i) {
              final data = docs[i].data();

              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: ListingCard(
                  id: docs[i].id,
                  data: data,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => PropertyDetailsPage(
                          propertyId: docs[i].id,
                          leadSource: DealLeadSource.search,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
