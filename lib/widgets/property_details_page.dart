import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/admin_action_service.dart';
import 'package:aqarai_app/services/caption_click_log_service.dart';
import 'package:aqarai_app/services/property_view_tracking_service.dart';

class PropertyDetailsPage extends StatelessWidget {
  final String propertyId;
  final bool isAdminView;

  /// How the user reached this screen (`property_views` + closure attribution).
  final String leadSource;

  /// Instagram A/B caption id from link `?cid=` (optional).
  final String? captionTrackingId;

  const PropertyDetailsPage({
    super.key,
    required this.propertyId,
    this.isAdminView = false,
    this.leadSource = DealLeadSource.direct,
    this.captionTrackingId,
  });

  String _translateType(BuildContext context, String value) {
    final loc = AppLocalizations.of(context)!;

    switch (value) {
      case "apartment":
        return loc.propertyType_apartment;
      case "house":
        return loc.propertyType_house;
      case "building":
        return loc.propertyType_building;
      case "land":
        return loc.propertyType_land;
      case "industrialLand":
        return loc.propertyType_industrialLand;
      case "shop":
        return loc.propertyType_shop;
      case "office":
        return loc.propertyType_office;
      case "chalet":
        return loc.propertyType_chalet;
      default:
        return value;
    }
  }

  String _translateService(BuildContext context, String value) {
    final loc = AppLocalizations.of(context)!;

    switch (value) {
      case "sale":
        return loc.forSale;
      case "rent":
        return loc.forRent;
      case "exchange":
        return loc.forExchange;
      default:
        return value;
    }
  }

  String _translateStatus(BuildContext context, String value) {
    final loc = AppLocalizations.of(context)!;

    switch (value) {
      case "active":
        return loc.active;
      case "pending":
        return "Pending";
      case "approved":
        return "Approved";
      case "rejected":
        return "Rejected";
      default:
        return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return _RecordPropertyViewOnce(
      propertyId: propertyId,
      leadSource: leadSource,
      skipRecording: isAdminView,
      captionTrackingId: captionTrackingId,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F7F7),

        appBar: AppBar(
          title: Text(
            loc.propertyDetails,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          actions: [
            if (FirebaseAuth.instance.currentUser != null && !isAdminView)
              _FavoriteHeart(propertyId: propertyId),
          ],
        ),

        body: FutureBuilder<DocumentSnapshot>(
          future: FirebaseFirestore.instance
              .collection('properties')
              .doc(propertyId)
              .get(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (!snapshot.hasData || !snapshot.data!.exists) {
              return Center(
                child: Text(
                  loc.noWantedItems,
                  style: const TextStyle(fontSize: 18),
                ),
              );
            }

            final data = snapshot.data!.data() as Map<String, dynamic>;

            final List<String> images = (data['images'] as List<dynamic>? ?? [])
                .map((e) => e.toString())
                .toList();

            final String type = data['type'] ?? '';
            final String serviceType = data['serviceType'] ?? '';
            final num price = (data['price'] ?? 0) as num;
            final String governorate =
                data['governorate'] ??
                data['governorateAr'] ??
                data['governorateEn'] ??
                '';
            final bool isAr =
                Localizations.localeOf(context).languageCode == 'ar';
            final String area =
                (isAr
                    ? (data['areaAr'] ?? data['area'])
                    : (data['areaEn'] ?? data['area'])) ??
                '';
            final String description = data['description'] ?? '';
            final String status = data['status'] ?? '';
            final Timestamp? createdAt = data['createdAt'] as Timestamp?;

            final String ownerName = data['fullName'] ?? "";
            final String ownerPhone = data['ownerPhone'] ?? "";
            final String ownerId = (data['ownerId'] ?? '').toString().trim();

            final int roomCount = (data['roomCount'] ?? 0) as int;
            final int masterRoomCount = (data['masterRoomCount'] ?? 0) as int;
            final int bathroomCount = (data['bathroomCount'] ?? 0) as int;
            final int parkingCount = (data['parkingCount'] ?? 0) as int;
            final double size = (data['size'] ?? 0).toDouble();

            final bool hasElevator = data['hasElevator'] ?? false;
            final bool hasCentralAC = data['hasCentralAC'] ?? false;
            final bool hasSplitAC = data['hasSplitAC'] ?? false;
            final bool hasMaidRoom = data['hasMaidRoom'] ?? false;
            final bool hasDriverRoom = data['hasDriverRoom'] ?? false;
            final bool hasLaundryRoom = data['hasLaundryRoom'] ?? false;
            final bool hasGarden = data['hasGarden'] ?? false;

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildImageSlider(images),
                const SizedBox(height: 16),

                _buildInfoCard(
                  context,
                  price,
                  governorate,
                  area,
                  _translateType(context, type),
                  _translateService(context, serviceType),
                  _translateStatus(context, status),
                ),

                const SizedBox(height: 16),

                _buildDescriptionCard(context, description),

                const SizedBox(height: 16),

                _buildFeaturesGrid(
                  context,
                  roomCount,
                  masterRoomCount,
                  bathroomCount,
                  parkingCount,
                  size,
                  hasElevator,
                  hasCentralAC,
                  hasSplitAC,
                  hasMaidRoom,
                  hasDriverRoom,
                  hasLaundryRoom,
                  hasGarden,
                ),

                const SizedBox(height: 16),

                if (isAdminView)
                  _buildOwnerCard(
                    context,
                    ownerName,
                    ownerPhone,
                    propertyId,
                    ownerId,
                  ),

                const SizedBox(height: 16),

                if (createdAt != null) _buildFooter(context, createdAt),

                const SizedBox(height: 24),

                if (!isAdminView)
                  _buildInterestedButton(
                    context,
                    propertyId,
                    type,
                    data['areaAr'] ?? '',
                    data['areaEn'] ?? '',
                    serviceType,
                    price,
                    _translateType(context, type),
                    _translateService(context, serviceType),
                    area,
                  ),
                const SizedBox(height: 32),
              ],
            );
          },
        ),
      ),
    );
  }

  static const String _whatsAppNumber = '96594442242';

  String _buildWhatsAppMessage(
    bool isArabic,
    String typeLabel,
    String serviceLabel,
    String areaLabel,
    num price,
  ) {
    final priceStr = price > 0
        ? NumberFormat.decimalPattern(isArabic ? 'ar' : 'en').format(price)
        : '-';
    if (isArabic) {
      return 'السلام عليكم ورحمة الله وبركاته\n'
          'أنا مهتم بهذا العقار.\n\n'
          'تفاصيل العقار:\n'
          '• نوع العقار: $typeLabel\n'
          '• المنطقة: $areaLabel\n'
          '• نوع الخدمة: $serviceLabel\n'
          '• السعر: $priceStr د.ك';
    } else {
      return 'Assalamu alaikum\n'
          'I\'m interested in this property.\n\n'
          'Property details:\n'
          '• Type: $typeLabel\n'
          '• Area: $areaLabel\n'
          '• Service: $serviceLabel\n'
          '• Price: $priceStr KWD';
    }
  }

  Future<void> _onInterestedTap(
    BuildContext context,
    String propertyId,
    String type,
    String areaAr,
    String areaEn,
    String serviceType,
    num price,
    String typeLabel,
    String serviceLabel,
    String areaLabel,
  ) async {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    try {
      await FirebaseFirestore.instance.collection('interested_leads').add({
        'propertyId': propertyId,
        'type': type,
        'areaAr': areaAr,
        'areaEn': areaEn,
        'serviceType': serviceType,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    final message = _buildWhatsAppMessage(
      isAr,
      typeLabel,
      serviceLabel,
      areaLabel,
      price,
    );
    final uri = Uri.parse(
      'https://wa.me/$_whatsAppNumber?text=${Uri.encodeComponent(message)}',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.noWantedItems)));
      }
    }
  }

  Widget _buildInterestedButton(
    BuildContext context,
    String propertyId,
    String type,
    String areaAr,
    String areaEn,
    String serviceType,
    num price,
    String typeLabel,
    String serviceLabel,
    String areaLabel,
  ) {
    final loc = AppLocalizations.of(context)!;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _onInterestedTap(
          context,
          propertyId,
          type,
          areaAr,
          areaEn,
          serviceType,
          price,
          typeLabel,
          serviceLabel,
          areaLabel,
        ),
        icon: const Icon(Icons.thumb_up, color: Colors.white),
        label: Text(
          loc.imInterested,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF25D366),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  Widget _buildImageSlider(List<String> images) {
    if (images.isEmpty) {
      return Container(
        height: 260,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.grey[300],
        ),
        child: const Icon(Icons.home, size: 70),
      );
    }

    return SizedBox(
      height: 260,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: PageView.builder(
          itemCount: images.length,
          itemBuilder: (context, index) {
            return Image.network(
              images[index],
              fit: BoxFit.cover,
              width: double.infinity,
            );
          },
        ),
      ),
    );
  }

  Widget _buildInfoCard(
    BuildContext context,
    num price,
    String governorate,
    String area,
    String type,
    String serviceType,
    String status,
  ) {
    final loc = AppLocalizations.of(context)!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "KWD $price",
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.green,
            ),
          ),
          const SizedBox(height: 12),

          Text("$governorate - $area", style: const TextStyle(fontSize: 18)),

          const SizedBox(height: 12),

          _rowInfo(loc.typeLabel, type),
          if (area.isNotEmpty) _rowInfo(loc.areaLabel, area),
          _rowInfo(loc.serviceTypeLabel, serviceType),
          _rowInfo(loc.statusLabel, status),
        ],
      ),
    );
  }

  Widget _buildDescriptionCard(BuildContext context, String description) {
    final loc = AppLocalizations.of(context)!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            loc.descriptionLabel,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            description.isEmpty ? loc.noDescription : description,
            style: const TextStyle(fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildFeaturesGrid(
    BuildContext context,
    int roomCount,
    int masterRoomCount,
    int bathroomCount,
    int parkingCount,
    double size,
    bool hasElevator,
    bool hasCentralAC,
    bool hasSplitAC,
    bool hasMaidRoom,
    bool hasDriverRoom,
    bool hasLaundryRoom,
    bool hasGarden,
  ) {
    final loc = AppLocalizations.of(context)!;

    final features = [
      _featureItem("${loc.roomCount}: $roomCount"),
      _featureItem("${loc.masterRoomCount}: $masterRoomCount"),
      _featureItem("${loc.bathroomCount}: $bathroomCount"),
      _featureItem("${loc.propertySize}: $size"),
      _featureItem("${loc.parkingCount}: $parkingCount"),
      _featureItem("${loc.hasElevator}: ${hasElevator ? "✓" : "✗"}"),
      _featureItem("${loc.hasCentralAC}: ${hasCentralAC ? "✓" : "✗"}"),
      _featureItem("${loc.hasSplitAC}: ${hasSplitAC ? "✓" : "✗"}"),
      _featureItem("${loc.hasMaidRoom}: ${hasMaidRoom ? "✓" : "✗"}"),
      _featureItem("${loc.hasDriverRoom}: ${hasDriverRoom ? "✓" : "✗"}"),
      _featureItem("${loc.hasLaundryRoom}: ${hasLaundryRoom ? "✓" : "✗"}"),
      _featureItem("${loc.hasGarden}: ${hasGarden ? "✓" : "✗"}"),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: features,
      ),
    );
  }

  Widget _featureItem(String text) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFEFEFEF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildOwnerCard(
    BuildContext context,
    String ownerName,
    String ownerPhone,
    String propertyId,
    String ownerId,
  ) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  loc.ownerOnlyAdmin,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (ownerId.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: loc.moderationMenu,
                  onSelected: (value) async {
                    if (value == 'ban') {
                      await confirmAndBanPropertyOwner(
                        context,
                        targetUid: ownerId,
                        isAr: isAr,
                      );
                    }
                  },
                  itemBuilder: (ctx) => [
                    PopupMenuItem<String>(
                      value: 'ban',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.block, color: Colors.red.shade800),
                        title: Text(loc.banUser),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 16),

          Text(
            "${loc.ownerNameLabel}: $ownerName",
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 6),

          Text(
            "${loc.ownerPhoneLabel}: $ownerPhone",
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 6),

          Text(
            "${loc.adIdLabel}: $propertyId",
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
          if (ownerId.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'ownerId: $ownerId',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          const SizedBox(height: 18),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                final clean = ownerPhone.replaceAll(" ", "");
                final uri = Uri.parse("tel:$clean");
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              icon: const Icon(Icons.phone, color: Colors.white),
              label: Text(
                loc.callOwner,
                style: const TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context, Timestamp createdAt) {
    final loc = AppLocalizations.of(context)!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Text(
        "${loc.addedOnDate} ${_formatDate(createdAt.toDate())}",
        style: const TextStyle(fontSize: 15, color: Colors.grey),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return "${date.year}-${date.month}-${date.day}";
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      boxShadow: [
        BoxShadow(
          color: Colors.grey.shade300,
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }

  Widget _rowInfo(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text("$label: $value", style: const TextStyle(fontSize: 16)),
    );
  }
}

/// One Firestore write per open; skipped for admin preview so metrics stay user-facing.
class _RecordPropertyViewOnce extends StatefulWidget {
  final String propertyId;
  final String leadSource;
  final bool skipRecording;
  final String? captionTrackingId;
  final Widget child;

  const _RecordPropertyViewOnce({
    required this.propertyId,
    required this.leadSource,
    required this.skipRecording,
    this.captionTrackingId,
    required this.child,
  });

  @override
  State<_RecordPropertyViewOnce> createState() =>
      _RecordPropertyViewOnceState();
}

class _RecordPropertyViewOnceState extends State<_RecordPropertyViewOnce> {
  @override
  void initState() {
    super.initState();
    if (!widget.skipRecording) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        PropertyViewTrackingService.instance.recordView(
          propertyId: widget.propertyId,
          leadSource: widget.leadSource,
        );
      });
    }
    final cid = widget.captionTrackingId?.trim();
    if (cid != null && cid.isNotEmpty && !widget.skipRecording) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        var area = '';
        try {
          final d = await FirebaseFirestore.instance
              .collection('properties')
              .doc(widget.propertyId)
              .get();
          area = (d.data()?['areaAr'] ?? '').toString();
        } catch (_) {}
        await CaptionClickLogService.logClick(
          captionId: cid,
          propertyId: widget.propertyId,
          area: area,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Heart icon that toggles favorite state for the current user.
class _FavoriteHeart extends StatelessWidget {
  final String propertyId;

  const _FavoriteHeart({required this.propertyId});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    final ref = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('favorites')
        .doc(propertyId);

    return StreamBuilder<DocumentSnapshot>(
      stream: ref.snapshots(),
      builder: (context, snapshot) {
        final isFavorite = snapshot.data?.exists ?? false;
        return IconButton(
          icon: Icon(
            isFavorite ? Icons.favorite : Icons.favorite_border,
            color: isFavorite ? Colors.red : null,
          ),
          onPressed: () async {
            try {
              if (isFavorite) {
                await ref.delete();
              } else {
                await ref.set({
                  'propertyId': propertyId,
                  'savedAt': FieldValue.serverTimestamp(),
                });
              }
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppLocalizations.of(context)!.noWantedItems),
                  ),
                );
              }
            }
          },
        );
      },
    );
  }
}

Future<void> confirmAndBanPropertyOwner(
  BuildContext context, {
  required String targetUid,
  required bool isAr,
}) async {
  final loc = AppLocalizations.of(context)!;
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(loc.banUserConfirmTitle),
      content: Text(loc.banUserConfirmMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(loc.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(loc.banUser),
        ),
      ],
    ),
  );
  if (confirm == true && context.mounted) {
    await AdminActionService.banUser(
      context: context,
      targetUid: targetUid,
      isAr: isAr,
    );
  }
}
