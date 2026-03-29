import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/widgets/property_details_page.dart';
import 'package:aqarai_app/models/listing_enums.dart';

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: Text(loc.favorites)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              isAr ? 'سجّل دخول عشان تشوف المفضلة.' : 'Sign in to see your favorites.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }

    final favoritesRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('favorites')
        .orderBy('savedAt', descending: true);

    return Scaffold(
      appBar: AppBar(title: Text(loc.favorites)),
      body: StreamBuilder<QuerySnapshot>(
        stream: favoritesRef.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('${snapshot.error}', textAlign: TextAlign.center),
              ),
            );
          }
          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  loc.favoritesEmpty,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final favDoc = docs[index];
              final propertyId = favDoc.id;
              return _FavoritePropertyTile(
                propertyId: propertyId,
                loc: loc,
                isAr: isAr,
              );
            },
          );
        },
      ),
    );
  }
}

class _FavoritePropertyTile extends StatefulWidget {
  final String propertyId;
  final AppLocalizations loc;
  final bool isAr;

  const _FavoritePropertyTile({
    required this.propertyId,
    required this.loc,
    required this.isAr,
  });

  @override
  State<_FavoritePropertyTile> createState() => _FavoritePropertyTileState();
}

class _FavoritePropertyTileState extends State<_FavoritePropertyTile> {
  bool _cleanupTriggered = false;

  String _typeLabel(String typeEn) {
    switch (typeEn.toLowerCase()) {
      case 'apartment':
        return widget.loc.propertyType_apartment;
      case 'house':
        return widget.loc.propertyType_house;
      case 'building':
        return widget.loc.propertyType_building;
      case 'land':
        return widget.loc.propertyType_land;
      case 'industrialland':
        return widget.loc.propertyType_industrialLand;
      case 'shop':
        return widget.loc.propertyType_shop;
      case 'office':
        return widget.loc.propertyType_office;
      case 'chalet':
        return widget.loc.propertyType_chalet;
      default:
        return typeEn;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance
          .collection('properties')
          .doc(widget.propertyId)
          .get(),
      builder: (context, snap) {
        if (snap.hasError) {
          final err = snap.error;
          if (err is FirebaseException && err.code == 'permission-denied') {
            if (!_cleanupTriggered) {
              _cleanupTriggered = true;
              final user = FirebaseAuth.instance.currentUser;
              if (user != null) {
                Future.microtask(() {
                  FirebaseFirestore.instance
                      .collection('users')
                      .doc(user.uid)
                      .collection('favorites')
                      .doc(widget.propertyId)
                      .delete();
                });
              }
            }
            return const SizedBox.shrink();
          }
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(title: Text('${snap.error}')),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Card(
            margin: EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: SizedBox(
                width: 56,
                height: 56,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              title: Text('...'),
            ),
          );
        }
        if (!snap.hasData || !snap.data!.exists) {
          if (!_cleanupTriggered) {
            _cleanupTriggered = true;
            final user = FirebaseAuth.instance.currentUser;
            if (user != null) {
              Future.microtask(() {
                FirebaseFirestore.instance
                    .collection('users')
                    .doc(user.uid)
                    .collection('favorites')
                    .doc(widget.propertyId)
                    .delete();
              });
            }
          }
          return const SizedBox.shrink();
        }
        final data = snap.data!.data()!;
        final type = data['type'] ?? '';
        final price = (data['price'] ?? 0) as num;
        final area = widget.isAr
            ? (data['areaAr'] ?? data['area'] ?? '')
            : (data['areaEn'] ?? data['area'] ?? '');
        final List<dynamic>? images = data['images'];
        final imageUrl = (images != null && images.isNotEmpty)
            ? images.first.toString()
            : null;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 3,
          child: InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      PropertyDetailsPage(
                        propertyId: widget.propertyId,
                        leadSource: DealLeadSource.direct,
                      ),
                ),
              );
            },
            borderRadius: BorderRadius.circular(12),
            child: Row(
              children: [
                if (imageUrl != null && imageUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      bottomLeft: Radius.circular(12),
                    ),
                    child: Image.network(
                      imageUrl,
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 100,
                        height: 100,
                        color: Colors.grey[300],
                        child: const Icon(Icons.home, size: 40),
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _typeLabel(type),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        if (area.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            area,
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 14,
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          'KWD $price',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
