import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/admin_action_service.dart';
import 'package:aqarai_app/services/caption_click_log_service.dart';
import 'package:aqarai_app/services/auction/auction_analytics_service.dart';
import 'package:aqarai_app/services/property_view_tracking_service.dart';
import 'package:aqarai_app/models/auction/auction_firestore_paths.dart';
import 'package:aqarai_app/models/auction/public_auction_lot.dart';
import 'package:aqarai_app/pages/seller_auction_approval_page.dart';
import 'package:aqarai_app/widgets/auction/auction_lot_rejection_strip.dart';
import 'package:aqarai_app/widgets/auction_registration_status_widget.dart';
import 'package:aqarai_app/services/interest_lead_flow_service.dart';
import 'package:aqarai_app/widgets/interested_lead_confirmation_sheet.dart';
import 'package:aqarai_app/widgets/chalet_booking_widget.dart';
import 'package:aqarai_app/widgets/booking_bar.dart';
import 'package:aqarai_app/widgets/booking_phone_capture_sheet.dart';
import 'package:aqarai_app/widgets/owner_booking_tools.dart';
import 'package:aqarai_app/services/featured_property_service.dart';
import 'package:aqarai_app/services/featured_suggestion_tracking_service.dart';
import 'package:aqarai_app/services/payment/payment_service.dart';
import 'package:aqarai_app/services/payment/payment_service_provider.dart';
import 'package:aqarai_app/services/ai_suggestions_auto_config_service.dart';
import 'package:aqarai_app/pages/video_page.dart';
import 'package:aqarai_app/utils/video_embed_url.dart';
import 'package:aqarai_app/utils/booking_rules.dart';
import 'package:aqarai_app/utils/listing_display.dart';
import 'package:aqarai_app/utils/property_price_display.dart';
import 'package:aqarai_app/services/ai_brain_service.dart';
import 'package:aqarai_app/app/property_route.dart';
import 'package:share_plus/share_plus.dart';
import 'package:aqarai_app/app/web_meta_helper.dart';

/// Human-friendly featured expiry line for owner CTA (Arabic / English).
String formatRemainingTime(DateTime featuredUntil, {bool isArabic = true}) {
  try {
    final now = DateTime.now();
    if (!featuredUntil.isAfter(now)) {
      return isArabic ? 'انتهى التمييز' : 'Feature expired';
    }
    final diff = featuredUntil.difference(now);
    final totalMinutes = diff.inMinutes;
    final minuteCount = totalMinutes < 1 ? 1 : totalMinutes;

    if (totalMinutes < 60) {
      return isArabic
          ? 'ينتهي خلال $minuteCount دقيقة'
          : 'Ends in $minuteCount min';
    }

    final totalHours = diff.inHours;
    if (totalHours < 24) {
      final h = totalHours < 1 ? 1 : totalHours;
      if (isArabic) {
        return h == 1
            ? 'ينتهي خلال ساعة'
            : 'ينتهي خلال $h ساعات';
      }
      return h == 1 ? 'Ends in 1 hour' : 'Ends in $h hours';
    }

    final d = diff.inDays;
    if (d < 3) {
      if (isArabic) {
        if (d <= 0) {
          return 'ينتهي خلال أقل من يوم';
        }
        if (d == 1) return 'ينتهي خلال يوم';
        if (d == 2) return 'ينتهي خلال يومين';
        return 'ينتهي خلال $d أيام';
      }
      if (d <= 0) return 'Ends in less than a day';
      return d == 1 ? 'Ends in 1 day' : 'Ends in $d days';
    }

    final dateStr = DateFormat('yyyy/MM/dd').format(featuredUntil);
    return isArabic ? 'ينتهي بتاريخ: $dateStr' : 'Ends on: $dateStr';
  } catch (_) {
    try {
      return DateFormat('yyyy/MM/dd – HH:mm').format(featuredUntil);
    } catch (_) {
      return featuredUntil.toIso8601String();
    }
  }
}

class PropertyDetailsPage extends StatefulWidget {
  final String propertyId;
  final bool isAdminView;

  /// How the user reached this screen (`property_views` + closure attribution).
  final String leadSource;

  /// Instagram A/B caption id from link `?cid=` (optional).
  final String? captionTrackingId;

  /// When opening from auction catalog: `public_lots` doc id for faster resolution.
  final String? auctionLotId;

  /// Optional sanity check against [PublicAuctionLot.auctionId].
  final String? auctionId;

  /// Optional check-in pre-selected by the caller (e.g. list page filter).
  /// Treated as a calendar day; time component is ignored.
  final DateTime? stayStart;

  /// Optional check-out (exclusive) pre-selected by the caller. Matches the
  /// semantics used in `property_list.dart` where
  /// `nights = stayEnd.difference(stayStart).inDays`.
  final DateTime? stayEnd;

  /// Rental filter propagated from the search/list screen (e.g. `"daily"` or
  /// `"monthly_yearly"`). When explicitly non-daily, the booking CTA is
  /// suppressed as an extra UX safety net on top of the server-parity check
  /// in [canShowBookingUI]. Null means "unknown / defer to listing data".
  final String? rentalType;

  const PropertyDetailsPage({
    super.key,
    required this.propertyId,
    this.isAdminView = false,
    this.leadSource = DealLeadSource.direct,
    this.captionTrackingId,
    this.auctionLotId,
    this.auctionId,
    this.stayStart,
    this.stayEnd,
    this.rentalType,
  });

  @override
  State<PropertyDetailsPage> createState() => _PropertyDetailsPageState();
}

class _PropertyDetailsPageState extends State<PropertyDetailsPage> {
  final ChaletBookingController _bookingController = ChaletBookingController();

  bool _trackedSuggestionShown = false;
  String? _lastShownEventId;
  String? _lastClickEventId;
  /// Debounce + loading UX while MyFatoorah session + checkout run.
  bool _featurePaymentLoading = false;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      debugPrint(
        '[LIFECYCLE] PropertyDetailsPage initState propertyId=${widget.propertyId} stayStart=${widget.stayStart} stayEnd=${widget.stayEnd}',
      );
    }
    _bookingController.reset();
    if (widget.stayStart != null && widget.stayEnd != null) {
      if (kDebugMode) {
        debugPrint(
          '[SEED] PropertyDetailsPage seed called start=${widget.stayStart} end=${widget.stayEnd}',
        );
      }
      _bookingController.seed(
        startDate: widget.stayStart,
        endDate: widget.stayEnd,
        nights: widget.stayEnd!.difference(widget.stayStart!).inDays,
      );
    } else {
      if (kDebugMode) {
        debugPrint(
          '[SEED] PropertyDetailsPage seed SKIPPED (stayStart or stayEnd is null)',
        );
      }
    }
  }

  @override
  void didUpdateWidget(covariant PropertyDetailsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.propertyId != oldWidget.propertyId) {
      _bookingController.reset();
    }
  }

  @override
  void dispose() {
    _bookingController.dispose();
    super.dispose();
  }

  Future<int?> _safeCount(Query<Map<String, dynamic>> q) async {
    try {
      final agg = await q.count().get();
      return agg.count;
    } catch (_) {
      return null;
    }
  }

  Future<_AiSuggestionMetrics> _loadSuggestionMetrics({
    required String propertyId,
    required DateTime now,
  }) async {
    final viewsQ = FirebaseFirestore.instance
        .collection('property_views')
        .where('propertyId', isEqualTo: propertyId);
    final inquiriesQ = FirebaseFirestore.instance
        .collection('deals')
        .where('propertyId', isEqualTo: propertyId);

    final views = await _safeCount(viewsQ);
    final inquiries = await _safeCount(inquiriesQ);
    return _AiSuggestionMetrics(
      viewsCount: views,
      inquiriesCount: inquiries,
      loadedAt: now,
    );
  }

  Future<void> _runFeatureFlow({
    required BuildContext context,
    required String propertyId,
    required String suggestionType,
    required AiSuggestionsAutoConfig cfg,
  }) async {
    if (!mounted) return;
    if (_featurePaymentLoading) return;
    setState(() => _featurePaymentLoading = true);
    try {
    final plan = await _pickPlan(context, cfg: cfg);
    if (plan == null) return;

    final shownId = _lastShownEventId;
    final clickId = await FeaturedSuggestionTrackingService.trackClicked(
      propertyId: propertyId,
      suggestionType: suggestionType,
      shownEventId: shownId ?? '',
      experimentId: 'ai_suggestions',
      variant: cfg.suggestionVariant,
      sessionIdOverride: FeaturedSuggestionTrackingService.sessionId,
    );
    _lastClickEventId = clickId;

    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    try {
      final ui = await PaymentServiceProvider.instance.payFeaturedAd(
        amountKwd: plan.priceKwd.toDouble(),
        durationDays: plan.durationDays,
        propertyId: propertyId,
        description: 'تمييز إعلان',
      );

      if (!ui.success) {
        if (!context.mounted) return;
        final msg = messageForFeaturedAdFailureAr(ui.failure);
        if (msg != null) {
          messenger.showSnackBar(
            SnackBar(content: Text(msg)),
          );
        }
        return;
      }

      final pid = ui.paymentId?.trim() ?? '';
      if (pid.isEmpty) {
        if (!context.mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text('فشل الدفع: رقم العملية غير متوفر'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      await FeaturedPropertyService.featurePropertyPaid(
        propertyId: propertyId,
        durationDays: plan.durationDays,
        amountKwd: plan.priceKwd.toDouble(),
        paymentId: pid,
        gateway: 'MyFatoorah',
      );

      await FeaturedSuggestionTrackingService.trackConversionSuccess(
        propertyId: propertyId,
        suggestionType: suggestionType,
        paymentId: pid,
        durationDays: plan.durationDays,
        amountKwd: plan.priceKwd.toDouble(),
        shownEventId: _lastShownEventId ?? '',
        clickEventId: _lastClickEventId ?? (clickId ?? ''),
        experimentId: 'ai_suggestions',
        variant: cfg.suggestionVariant,
        sessionIdOverride: FeaturedSuggestionTrackingService.sessionId,
      );

      if (!context.mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('تم تمييز الإعلان بنجاح'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('خطأ: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
    } finally {
      if (mounted) setState(() => _featurePaymentLoading = false);
    }
  }

  Future<_FeaturePlan?> _pickPlan(
    BuildContext context, {
    required AiSuggestionsAutoConfig cfg,
  }) async {
    const primary = Color(0xFF101046);
    const plans = <_FeaturePlan>[
      _FeaturePlan(durationDays: 3, priceKwd: 5, labelAr: '٣ أيام'),
      _FeaturePlan(durationDays: 7, priceKwd: 10, labelAr: '٧ أيام'),
      _FeaturePlan(durationDays: 14, priceKwd: 15, labelAr: '١٤ يوم'),
      _FeaturePlan(durationDays: 30, priceKwd: 25, labelAr: '٣٠ يوم'),
    ];

    return showModalBottomSheet<_FeaturePlan>(
      context: context,
      showDragHandle: true,
      isScrollControlled: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'اختر مدة التمييز',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                for (final p in plans) ...[
                  _PlanTile(
                    plan: p,
                    highlight: p.durationDays == cfg.defaultPlanDays,
                    onTap: () => Navigator.pop(ctx, p),
                    primary: primary,
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

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
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    switch (value) {
      case ListingStatus.pendingUpload:
        return isAr ? 'بانتظار رفع الصورة' : 'Pending photo upload';
      case ListingStatus.pendingApproval:
        return isAr ? 'بانتظار الاعتماد' : 'Pending approval';
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
    final bool showOwnerTools = false;
    final loc = AppLocalizations.of(context)!;

    return _RecordPropertyViewOnce(
      propertyId: widget.propertyId,
      leadSource: widget.leadSource,
      skipRecording: widget.isAdminView,
      captionTrackingId: widget.captionTrackingId,
      auctionLotId: widget.auctionLotId,
      child: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance
            .collection('properties')
            .doc(widget.propertyId)
            .get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: Color(0xFFF7F7F7),
              body: Center(child: CircularProgressIndicator()),
            );
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return Scaffold(
              backgroundColor: const Color(0xFFF7F7F7),
              body: Center(
                child: Text(
                  loc.noWantedItems,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
            );
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;

          if (kIsWeb) {
            final canonicalUrl =
                '${Uri.base.origin}${Uri.base.path}'
                '${Uri.base.hasQuery ? '?${Uri.base.query}' : ''}';
            WidgetsBinding.instance.addPostFrameCallback((_) {
              updatePropertyMeta(data, canonicalUrl);
            });
          }

          // Read once per rebuild and reuse — avoids walking the map +
          // trimming on every conditional widget.
          final chaletName = listingChaletName(data);

          final List<String> images = (data['images'] as List<dynamic>? ?? [])
              .map((e) => e.toString())
              .toList();

          final String videoUrlRaw = (data['videoUrl'] ?? '').toString().trim();
          final String? videoEmbed =
              videoUrlRaw.isNotEmpty
                  ? VideoEmbedUrl.parseToEmbedUrl(videoUrlRaw)
                  : null;

          final String type = data['type'] ?? '';
          final String serviceType = data['serviceType'] ?? '';
          final num price = (data['price'] ?? 0) as num;
          final num? weekendPriceRaw =
              data['chaletWeekendPricePerNight'] ?? data['weekendPricePerNight'];
          final double? chaletWeekendPrice =
              (weekendPriceRaw != null &&
                      weekendPriceRaw > price &&
                      weekendPriceRaw > 0)
                  ? weekendPriceRaw.toDouble()
                  : null;
          List<int>? chaletPeakWeekdays;
          final rawPeakDays =
              data['chaletWeekendWeekdays'] ?? data['weekendWeekdays'];
          if (rawPeakDays is List && rawPeakDays.isNotEmpty) {
            chaletPeakWeekdays = rawPeakDays
                .map((e) {
                  if (e is int) return e;
                  if (e is num) return e.toInt();
                  return null;
                })
                .whereType<int>()
                .where((e) => e >= 1 && e <= 7)
                .toList();
            if (chaletPeakWeekdays.isEmpty) chaletPeakWeekdays = null;
          }
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
          final listingTitleForSemantics = listingDisplayTitle(
            data,
            areaLabel: area,
            typeLabel: _translateType(context, type),
          );
          final String description = data['description'] ?? '';
          final String status = data['status'] ?? '';
          final Timestamp? createdAt = data['createdAt'] as Timestamp?;
          final Timestamp? featuredUntilTs = data['featuredUntil'] as Timestamp?;
          final DateTime? featuredUntil = featuredUntilTs?.toDate();

          final String ownerName = data['fullName'] ?? "";
          final String ownerPhone = data['ownerPhone'] ?? "";
          final String ownerId = (data['ownerId'] ?? '').toString().trim();
          final String? uid = FirebaseAuth.instance.currentUser?.uid;
          final bool isOwner = uid != null && uid.isNotEmpty && uid == ownerId;
          final bool isAdmin = widget.isAdminView;

          final bool isChaletRentListing = canShowBookingUI(data);
          // When the caller explicitly passes a non-"daily" rentalType (e.g.
          // the list page was filtering monthly/yearly), we must not surface
          // the booking CTA. Missing/unknown rentalType defers to the
          // listing-level `canShowBookingUI` gate which already mirrors the
          // server's `effectiveChaletMode == "daily"` check.
          final String? rentalTypeHint =
              widget.rentalType?.trim().toLowerCase();
          final bool rentalTypeAllowsBooking =
              rentalTypeHint == null ||
                  rentalTypeHint.isEmpty ||
                  rentalTypeHint == 'daily';
          final bool canSeeBooking = isChaletRentListing &&
              rentalTypeAllowsBooking &&
              !isOwner &&
              !isAdmin;

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
          final bool hasPoolIndoor = data['hasPoolIndoor'] ?? false;
          final bool hasPoolOutdoor = data['hasPoolOutdoor'] ?? false;
          final bool isBeachfront = data['isBeachfront'] ?? false;

          return Scaffold(
            backgroundColor: const Color(0xFFF7F7F7),
            appBar: AppBar(
              title: Text(
                loc.propertyDetails,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              centerTitle: true,
              actions: [
                IconButton(
                  tooltip: isAr ? 'مشاركة الرابط' : 'Share listing link',
                  icon: const Icon(Icons.ios_share_rounded),
                  onPressed: () async {
                    final url = PropertyRoute.publicShareUrl(widget.propertyId);
                    if (kIsWeb) {
                      await Clipboard.setData(ClipboardData(text: url));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(loc.instagramPostLinkCopied),
                        ),
                      );
                    } else {
                      await SharePlus.instance.share(ShareParams(text: url));
                    }
                  },
                ),
                if (FirebaseAuth.instance.currentUser != null && !isAdmin)
                  _FavoriteHeart(propertyId: widget.propertyId),
              ],
            ),
            bottomNavigationBar: canSeeBooking
                ? ListenableBuilder(
                    // Show the sticky CTA only once the user has a valid
                    // date range (or is mid-submit). Keeps the spec promise
                    // "no empty bar frame when dates are not picked" and
                    // avoids rendering a disabled placeholder button.
                    listenable: Listenable.merge([
                      _bookingController.canBookVN,
                      _bookingController.submittingVN,
                      _bookingController.nightsVN,
                    ]),
                    builder: (context, _) {
                      final hasDates = _bookingController.nights > 0;
                      final canBook = _bookingController.canBook;
                      final submitting = _bookingController.submitting;
                      // canBook already encodes: dates picked AND valid AND
                      // available AND not currently submitting. Combining
                      // with [submitting] keeps the bar visible through the
                      // CTA's loading state without flickering.
                      final visible = hasDates && (canBook || submitting);
                      if (!visible) return const SizedBox.shrink();
                      return BookingBar(
                        controller: _bookingController,
                        pricePerNight: price.toDouble(),
                      );
                    },
                  )
                : null,
            body: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                canSeeBooking ? 100 : 16,
              ),
              children: [
                if (chaletName.isEmpty && listingTitleForSemantics.trim().isNotEmpty)
                  Semantics(
                    header: true,
                    label: listingTitleForSemantics.trim(),
                    child: const SizedBox.shrink(),
                  ),
                _buildImageSlider(
                  context,
                  images,
                  listingSemanticCaption: listingTitleForSemantics,
                  isArabic: isAr,
                ),
                // Optional owner-provided chalet name — shown as a large
                // prominent heading right below the image. Only renders when
                // the listing actually has a `chaletName`, so historical
                // listings keep their layout identical.
                if (chaletName.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    header: true,
                    label: listingTitleForSemantics,
                    child: Text(
                      chaletName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
                if (videoEmbed != null) ...[
                  const SizedBox(height: 12),
                  _PropertyVideoPreviewCard(videoUrl: videoUrlRaw),
                ],
                if (canSeeBooking) ...[
                  const SizedBox(height: 16),
                  _buildChaletBookingConversionCard(
                    context: context,
                    isAr: isAr,
                    price: price,
                    chaletWeekendPrice: chaletWeekendPrice,
                    chaletPeakWeekdays: chaletPeakWeekdays,
                    propertyId: widget.propertyId,
                    area: area,
                    typeLabel: _translateType(context, type),
                    imageUrl: images.isNotEmpty ? images.first.toString() : '',
                    listingData: data,
                    initialStayStart: widget.stayStart,
                    initialStayEnd: widget.stayEnd,
                  ),
                ],
                if (showOwnerTools && // ignore: dead_code
                    isChaletRentListing && // ignore: dead_code
                    isOwner && // ignore: dead_code
                    !isAdmin) ...[ // ignore: dead_code
                  const SizedBox(height: 16),
                  OwnerBookingTools(propertyId: widget.propertyId),
                ],
                const SizedBox(height: 16),

                _buildInfoCard(
                  context,
                  price,
                  governorate,
                  area,
                  _translateType(context, type),
                  _translateService(context, serviceType),
                  _translateStatus(context, status),
                  isAr: isAr,
                  serviceTypeRaw: serviceType,
                  priceTypeRaw: data['priceType']?.toString(),
                  bookingForTotalLine:
                      canSeeBooking &&
                              resolveDisplayPriceType(
                                    serviceType: serviceType,
                                    priceType: data['priceType']?.toString(),
                                  ) ==
                                  DisplayPriceType.daily
                          ? _bookingController
                          : null,
                  hideHeroPrice: isChaletRentListing,
                  chaletPerNightPrice: isChaletRentListing,
                ),

                // Yield / ROI card — Phase 1. Shown only for sale listings
                // of multi-unit-friendly types. Backend is the single source
                // of truth for the numbers; the widget never invents them.
                if (serviceType == 'sale' &&
                    (type == 'building' || type == 'house')) ...[
                  const SizedBox(height: 12),
                  _YieldCard(
                    propertyId: widget.propertyId,
                    cachedRoi: data['roi'] is Map
                        ? Map<String, dynamic>.from(data['roi'] as Map)
                        : null,
                    isArabic: isAr,
                  ),
                ],

                if (!isAdmin && isOwner) ...[
                  const SizedBox(height: 14),
                  StreamBuilder<AiSuggestionsAutoConfig>(
                    stream: AiSuggestionsAutoConfigService.watch(),
                    builder: (context, cfgSnap) {
                      final rawCfg = cfgSnap.data ?? AiSuggestionsAutoConfig.defaults;
                      final cfg = rawCfg.aiEnabled
                          ? rawCfg
                          : AiSuggestionsAutoConfig.defaults;
                      return FutureBuilder<_AiSuggestionMetrics>(
                        future: _loadSuggestionMetrics(
                          propertyId: widget.propertyId,
                          now: DateTime.now(),
                        ),
                        builder: (context, mSnap) {
                          final now = DateTime.now();

                          final isFeaturedNow =
                              featuredUntil != null && featuredUntil.isAfter(now);
                          final hasFeaturedBefore = featuredUntil != null;
                          final isExpired = hasFeaturedBefore &&
                              featuredUntil.isBefore(now);
                          final endingSoon = isFeaturedNow &&
                              featuredUntil.isBefore(now.add(const Duration(days: 2)));
                          final urgent = isFeaturedNow &&
                              featuredUntil.isBefore(now.add(const Duration(days: 1)));

                          final ageDays = createdAt == null
                              ? null
                              : now.difference(createdAt.toDate()).inDays;

                          final metrics = mSnap.data;
                          final views = metrics?.viewsCount;
                          final inquiries = metrics?.inquiriesCount;

                          final exposure = cfg.exposureMultiplier.clamp(0.6, 1.8);
                          final lowViewsThreshold = (10 * exposure).round().clamp(5, 25);
                          final noInquiryAfterDays = (5 / exposure).round().clamp(2, 7);
                          const newlyAddedDays = 2;

                          final reasons = <String>[];

                          if (!isFeaturedNow) {
                            reasons.add('not_featured');
                          } else if (endingSoon) {
                            reasons.add('ending_soon');
                          }

                          if (ageDays != null && ageDays <= newlyAddedDays) {
                            reasons.add('newly_added');
                          }
                          if (views != null && views < lowViewsThreshold) {
                            reasons.add('low_views');
                          }
                          if (ageDays != null &&
                              ageDays >= noInquiryAfterDays &&
                              inquiries != null &&
                              inquiries == 0) {
                            reasons.add('no_inquiries');
                          }

                          final shouldSuggest =
                              reasons.isNotEmpty && (!isFeaturedNow || endingSoon);
                          if (!shouldSuggest) return const SizedBox.shrink();

                          final suggestionType =
                              isFeaturedNow ? 'extend' : 'feature';

                          if (!_trackedSuggestionShown) {
                            _trackedSuggestionShown = true;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              FeaturedSuggestionTrackingService.trackShown(
                                propertyId: widget.propertyId,
                                suggestionType: suggestionType,
                                reasons: reasons,
                                experimentId: 'ai_suggestions',
                                variant: cfg.suggestionVariant,
                                sessionIdOverride: FeaturedSuggestionTrackingService.sessionId,
                              ).then((id) {
                                _lastShownEventId ??= id;
                              });
                            });
                          }

                          final buttonLabel = isFeaturedNow
                              ? 'مدد التمييز'
                              : (isExpired
                                  ? 'إعادة التمييز'
                                  : 'اجعله مميزًا');

                          final String? featureButtonSubtitle =
                              (isExpired || isFeaturedNow)
                                  ? formatRemainingTime(
                                      featuredUntil,
                                      isArabic: isAr,
                                    )
                                  : null;

                          final bool urgentCard =
                              urgent && cfg.urgencyLevel >= 2;
                          final Color? featureAccentOverride = urgentCard
                              ? null
                              : (isFeaturedNow
                                  ? const Color(0xFF2E7D32)
                                  : (isExpired
                                      ? Colors.grey.shade700
                                      : null));

                          String message() {
                            final strong = cfg.suggestionVariant == 'B';

                            if (urgent && cfg.urgencyLevel >= 2) {
                              return '⏳ آخر فرصة! باقي أقل من يوم على انتهاء التمييز — مدد الآن لتبقى في أعلى النتائج';
                            }
                            if (urgent) {
                              return '⏳ باقي أقل من يوم على انتهاء التمييز — مدد الآن لتبقى في أعلى النتائج';
                            }
                            if (endingSoon) {
                              return strong
                                  ? 'التمييز قارب ينتهي — مدد الآن عشان ما ينزل إعلانك بالنتائج'
                                  : 'قارب التمييز على الانتهاء — مدد إعلانك لتستمر بالظهور في أعلى النتائج';
                            }
                            if (reasons.contains('no_inquiries')) {
                              return strong
                                  ? 'ولا استفسار حتى الآن — خلنا نرفع ظهور إعلانك بتمييزه'
                                  : 'ما وصلتك استفسارات حتى الآن — ميز إعلانك للحصول على تفاعل أكثر';
                            }
                            if (reasons.contains('low_views')) {
                              if (views != null) {
                                return strong
                                    ? 'مشاهداتك قليلة ($views) — التمييز يرفع إعلانك لأعلى النتائج'
                                    : 'مشاهدات إعلانك قليلة ($views) — ميزه ليظهر في أعلى النتائج';
                              }
                              return strong
                                  ? 'مشاهداتك قليلة — التمييز يرفع إعلانك لأعلى النتائج'
                                  : 'مشاهدات إعلانك قليلة — ميزه ليظهر في أعلى النتائج';
                            }
                            if (reasons.contains('newly_added')) {
                              return strong
                                  ? 'إعلانك جديد — ابدأ قوي بتمييزه عشان يوصل لأكبر عدد'
                                  : 'إعلانك جديد — ميّزه من البداية ليصل لعدد أكبر من المهتمين';
                            }
                            return strong
                                ? 'تمييز إعلانك = ظهور أعلى + مشاهدات أكثر'
                                : 'ميز إعلانك ليظهر في أعلى النتائج ويحصل على مشاهدات أكثر';
                          }

                          return _AiSuggestionCard(
                            title: 'إعلانك يحتاج تعزيز 🚀',
                            message: message(),
                            buttonText: buttonLabel,
                            buttonSubtitle: featureButtonSubtitle,
                            accentOverride: featureAccentOverride,
                            urgent: urgentCard,
                            isLoading: _featurePaymentLoading,
                            onPressed: _featurePaymentLoading
                                ? null
                                : () => _runFeatureFlow(
                                      context: context,
                                      propertyId: widget.propertyId,
                                      suggestionType: suggestionType,
                                      cfg: cfg,
                                    ),
                          );
                        },
                      );
                    },
                  ),
                ],

                if (!isAdmin &&
                    widget.auctionLotId != null &&
                    widget.auctionLotId!.trim().isNotEmpty)
                  _AuctionRegistrationForLot(
                    lotDocId: widget.auctionLotId!.trim(),
                    expectedAuctionId: widget.auctionId,
                    listingPrice: price.toDouble(),
                  ),

                if (!isAdmin &&
                    widget.auctionLotId != null &&
                    widget.auctionLotId!.trim().isNotEmpty)
                  _AuctionLotPublicRejectionStrip(
                    lotDocId: widget.auctionLotId!.trim(),
                    expectedAuctionId: widget.auctionId,
                  ),

                if (!isAdmin &&
                    widget.auctionLotId != null &&
                    widget.auctionLotId!.trim().isNotEmpty &&
                    ownerId.isNotEmpty &&
                    FirebaseAuth.instance.currentUser?.uid == ownerId)
                  _SellerAuctionOutcomeEntry(
                    lotId: widget.auctionLotId!.trim(),
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
                  hasPoolIndoor,
                  hasPoolOutdoor,
                  isBeachfront,
                  showUncheckedBooleanFeatures: isAdmin,
                ),

                const SizedBox(height: 16),

                if (isAdmin)
                  PropertyDetailsAdminControls(
                    ownerName: ownerName,
                    ownerPhone: ownerPhone,
                    propertyId: widget.propertyId,
                    ownerId: ownerId,
                  ),

                const SizedBox(height: 16),

                if (createdAt != null) _buildFooter(context, createdAt),

                const SizedBox(height: 24),

                // Rent chalets: booking module is primary; others use interest CTA.
                if (!isChaletRentListing)
                  _buildInterestedButton(
                    context,
                    widget.propertyId,
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
            ),
          );
        },
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
    String phone,
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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await InterestLeadFlowService.saveUserPhone(uid: user.uid, phone: phone);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isAr
                  ? 'تعذر حفظ رقم الهاتف. حاول مرة أخرى.'
                  : 'Could not save your phone number. Please try again.',
            ),
          ),
        );
      }
      return;
    }

    try {
      await InterestLeadFlowService.ensureInterestDeal(
        phone: phone,
        propertyId: propertyId,
        propertyTitle: '$areaLabel • $typeLabel',
        propertyPrice: price,
        serviceTypeRaw: serviceType,
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isAr
                  ? 'تعذر إتمام الطلب. حاول لاحقاً.'
                  : 'Could not complete your request. Try again later.',
            ),
          ),
        );
      }
      return;
    }

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
        onPressed: () async {
          final phone = await showInterestedLeadPhoneSheet(context);
          if (!context.mounted || phone == null) return;
          await _onInterestedTap(
            context,
            phone,
            propertyId,
            type,
            areaAr,
            areaEn,
            serviceType,
            price,
            typeLabel,
            serviceLabel,
            areaLabel,
          );
        },
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

  String _formatKwdDisplayAmount(num value, {required bool isAr}) {
    final d = value.toDouble();
    final r = d.round();
    final useInt = (d - r).abs() < 1e-9;
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');
    return useInt ? fmt.format(r) : fmt.format(d);
  }

  String _perNightPriceLine(num price, bool isAr) {
    final a = _formatKwdDisplayAmount(price, isAr: isAr);
    return isAr ? '$a د.ك / الليلة' : '$a KWD / night';
  }

  String _heroPriceWithUnit(
    num price,
    bool isAr,
    String serviceTypeRaw,
    String? priceTypeRaw,
  ) {
    final displayType = resolveDisplayPriceType(
      serviceType: serviceTypeRaw,
      priceType: priceTypeRaw,
    );
    final core = _formatKwdDisplayAmount(price, isAr: isAr);
    final suffix = priceSuffix(displayType, isAr);
    return isAr ? '$core د.ك$suffix' : '$core KWD$suffix';
  }

  Future<void> _onChaletPrimaryCtaTap(
    BuildContext context,
    bool isAr,
    Map<String, dynamic> listingData,
  ) async {
    if (!_bookingController.canBook) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            isAr
                ? 'يرجى اختيار تواريخ الوصول والمغادرة'
                : 'Please select check-in and check-out dates',
          ),
        ),
      );
      return;
    }
    if (!listingDataIsPubliclyDiscoverable(listingData)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            isAr
                ? 'هذا العقار غير متاح للحجز حالياً'
                : 'This property is not available for booking right now.',
          ),
        ),
      );
      return;
    }
    if (_bookingController.submitting) return;

    // One-time phone-number capture. We keep this purely client-side and
    // do NOT touch booking / payment logic: the phone is persisted to
    // `users/{uid}.phone` (via InterestLeadFlowService.saveUserPhone), and
    // the server-side admin-monitoring email already reads from that path.
    final ok = await _ensureClientPhoneCaptured(context, isAr);
    if (!ok) return;
    if (!context.mounted) return;

    // Re-check after the async gap — state may have changed while the
    // bottom sheet was up (e.g. dates got invalidated, another submit was
    // kicked off by the bar).
    if (!_bookingController.canBook) return;
    if (_bookingController.submitting) return;
    _bookingController.submit();
  }

  /// Guarantees the signed-in user has a valid saved Kuwaiti phone before
  /// the booking proceeds. Returns `true` if the flow should continue,
  /// `false` if the user dismissed / is not signed in / save failed.
  ///
  /// Behavior:
  ///  - Missing / invalid stored phone → force the capture bottom sheet.
  ///  - Valid stored phone → light "continue / edit" confirm sheet.
  ///  - If the user is not signed in, we fall through `true` so the
  ///    existing submit path can surface its own auth error (no change
  ///    to existing booking logic).
  Future<bool> _ensureClientPhoneCaptured(
    BuildContext context,
    bool isAr,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      // Let the normal submit path handle auth errors.
      return true;
    }

    final existing = await readSavedUserPhone(user.uid);
    if (!context.mounted) return false;

    if (!BookingPhoneValidator.isValidKuwaiti(existing)) {
      final captured = await showBookingPhoneCaptureSheet(
        context,
        initial: existing, // prefill if a legacy / partial value was present
      );
      return captured != null;
    }

    final choice = await showBookingPhoneConfirmSheet(
      context,
      existingPhone: existing,
    );
    if (choice == null) return false;
    if (choice == BookingPhoneConfirmChoice.continueBooking) return true;

    if (!context.mounted) return false;
    final edited = await showBookingPhoneCaptureSheet(
      context,
      initial: existing,
    );
    return edited != null;
  }

  Widget _buildChaletBookingConversionCard({
    required BuildContext context,
    required bool isAr,
    required num price,
    required double? chaletWeekendPrice,
    required List<int>? chaletPeakWeekdays,
    required String propertyId,
    required String area,
    required String typeLabel,
    required String imageUrl,
    required Map<String, dynamic> listingData,
    DateTime? initialStayStart,
    DateTime? initialStayEnd,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final locale = isAr ? 'ar' : 'en_US';
    final dateFmt = DateFormat.yMMMEd(locale);
    final double? peakNightly = chaletWeekendPrice;

    return Material(
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(18),
      color: cs.surface,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.verified_outlined,
                  size: 18,
                  color: cs.primary.withValues(alpha: 0.85),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isAr ? 'متاح الآن' : 'Available now',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: cs.primary.withValues(alpha: 0.9),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isAr
                  ? 'الحجز يتم فوراً بعد الدفع'
                  : 'Booking completes right after payment',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.62),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _perNightPriceLine(price, isAr),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.primary,
              ),
            ),
            if (peakNightly != null && peakNightly > price.toDouble()) ...[
              const SizedBox(height: 6),
              Text(
                isAr
                    ? 'ذروة ليالي محدّدة: ${_perNightPriceLine(peakNightly, isAr)}'
                    : 'Peak nights: ${_perNightPriceLine(peakNightly, isAr)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.68),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Divider(height: 1, color: cs.outline.withValues(alpha: 0.2)),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: Listenable.merge([
                _bookingController.nightsVN,
                _bookingController.totalPriceVN,
                _bookingController.canBookVN,
                _bookingController.submittingVN,
                _bookingController.isProvisionalVN,
              ]),
              builder: (context, _) {
                final s = _bookingController.startDate;
                final e = _bookingController.endDate;
                final nights = _bookingController.nights;
                final total = _bookingController.totalPrice;
                final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');
                final cur = isAr ? 'د.ك' : 'KWD';
                final checkOutDisplay = e != null
                    ? DateTime(e.year, e.month, e.day)
                    : null;
                final ppn = price.toDouble();
                final flatProduct = ppn * nights;
                final breakdownLine = nights > 0
                    ? (isAr
                        ? ((total - flatProduct).abs() < 0.005
                            ? '${fmt.format(ppn)} × $nights ليالي = ${fmt.format(total)} $cur'
                            : '${fmt.format(total)} $cur · ليالي عادية وذروة ($nights ليالي)')
                        : ((total - flatProduct).abs() < 0.005
                            ? '${fmt.format(ppn)} × $nights nights = ${fmt.format(total)} $cur'
                            : '${fmt.format(total)} $cur · weekday/peak ($nights nights)'))
                    : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isAr ? 'الوصول' : 'Check-in',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: cs.onSurface.withValues(alpha: 0.55),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                s != null ? dateFmt.format(s) : '—',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isAr ? 'المغادرة' : 'Check-out',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: cs.onSurface.withValues(alpha: 0.55),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                checkOutDisplay != null
                                    ? dateFmt.format(checkOutDisplay)
                                    : '—',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      isAr ? 'عدد الليالي: $nights' : 'Nights: $nights',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 240),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) {
                        return FadeTransition(
                          opacity: anim,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.98, end: 1).animate(
                              CurvedAnimation(
                                parent: anim,
                                curve: Curves.easeOutCubic,
                              ),
                            ),
                            child: child,
                          ),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey<String>('${total}_$nights'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              isAr
                                  ? 'الإجمالي: ${fmt.format(total)} $cur'
                                  : 'Total: ${fmt.format(total)} $cur',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: isAr ? 0 : -0.2,
                                height: 1.2,
                              ),
                            ),
                            if (breakdownLine != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                breakdownLine,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurface.withValues(alpha: 0.68),
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            ChaletBookingWidget(
              propertyId: propertyId,
              pricePerNight: price.toDouble(),
              propertyTitle: listingDisplayTitle(
                listingData,
                areaLabel: area,
                typeLabel: typeLabel,
              ),
              imageUrl: imageUrl,
              controller: _bookingController,
              useExternalBookingBar: true,
              minNights: 1,
              weekendPricePerNight: chaletWeekendPrice,
              peakNightWeekdays: chaletPeakWeekdays,
              compactLayoutForPropertyDetails: true,
              allowPublicBooking: listingDataIsPubliclyDiscoverable(listingData),
              initialStartDate: initialStayStart,
              initialEndDate: initialStayEnd,
            ),
            const SizedBox(height: 18),
            Text(
              isAr ? 'متاح الآن — الحجز يتم فوراً' : 'Available now — book instantly',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                color: cs.primary.withValues(alpha: 0.92),
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: Listenable.merge([
                _bookingController.canBookVN,
                _bookingController.submittingVN,
              ]),
              builder: (context, _) {
                final busy = _bookingController.submitting;
                return SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: busy
                        ? null
                        : () => _onChaletPrimaryCtaTap(context, isAr, listingData),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: busy
                        ? SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: cs.onPrimary,
                            ),
                          )
                        : Text(
                            isAr
                                ? 'احجز الآن • الدفع فوري'
                                : 'Book now • Instant payment',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
            Text(
              isAr ? 'الدفع آمن 100%' : '100% secure payment',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.62),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isAr ? 'تأكيد فوري للحجز' : 'Instant booking confirmation',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.62),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSlider(
    BuildContext context,
    List<String> images, {
    required String listingSemanticCaption,
    required bool isArabic,
  }) {
    if (images.isEmpty) {
      final isAr = isArabic;
      return Container(
        height: 260,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.grey[200],
          border: Border.all(color: Colors.grey.shade400),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 56,
              color: Colors.grey.shade600,
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                isAr ? 'لا توجد صور مرفوعة لهذا الإعلان' : 'No photos uploaded yet',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = MediaQuery.sizeOf(context).width;
    final memW = (w * dpr).round().clamp(600, 2200);
    return _PropertyImageCarousel(
      images: images,
      height: 260,
      borderRadius: 14,
      memCacheWidth: memW,
      listingSemanticCaption: listingSemanticCaption,
      isArabic: isArabic,
    );
  }

  Widget _buildInfoCard(
    BuildContext context,
    num price,
    String governorate,
    String area,
    String type,
    String serviceType,
    String status, {
    required bool isAr,
    required String serviceTypeRaw,
    String? priceTypeRaw,
    ChaletBookingController? bookingForTotalLine,
    bool hideHeroPrice = false,
    bool chaletPerNightPrice = false,
  }) {
    final loc = AppLocalizations.of(context)!;
    final displayType = resolveDisplayPriceType(
      serviceType: serviceTypeRaw,
      priceType: priceTypeRaw,
    );
    final heroPriceText = chaletPerNightPrice
        ? _perNightPriceLine(price, isAr)
        : _heroPriceWithUnit(price, isAr, serviceTypeRaw, priceTypeRaw);
    final priceSemanticsLabel =
        isAr ? 'السعر: $heroPriceText' : 'Price: $heroPriceText';

    final locationOneLine = '$governorate - $area';
    final trimmedLocationLine = locationOneLine.trim();
    final locationSemanticsLabel = trimmedLocationLine.isEmpty
        ? (isAr ? 'الموقع غير متوفر' : 'Location unavailable')
        : (isAr ? 'الموقع: $trimmedLocationLine' : 'Location: $trimmedLocationLine');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hideHeroPrice) ...[
            Semantics(
              label: priceSemanticsLabel,
              excludeSemantics: true,
              container: true,
              child: SelectableText(
                heroPriceText,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.green,
                ),
              ),
            ),
            if (bookingForTotalLine != null &&
                displayType == DisplayPriceType.daily &&
                price > 0) ...[
              ListenableBuilder(
                listenable: bookingForTotalLine.nightsVN,
                builder: (context, _) {
                  final n = bookingForTotalLine.nights;
                  if (n <= 0) return const SizedBox.shrink();
                  final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');
                  final total = price * n;
                  final line = isAr
                      ? 'الإجمالي: ${fmt.format(total)} د.ك'
                      : 'Total: ${fmt.format(total)} KWD';
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Semantics(
                      label:
                          isAr
                              ? 'إجمالي الإقامة: $line'
                              : 'Booking total: $line',
                      excludeSemantics: true,
                      container: true,
                      child: SelectableText(
                        line,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey[800],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
            const SizedBox(height: 12),
          ],

          Semantics(
            label: locationSemanticsLabel,
            excludeSemantics: true,
            container: true,
            child: SelectableText(
              locationOneLine,
              style: const TextStyle(fontSize: 18),
            ),
          ),

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
          SelectableText(
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
    bool hasPoolIndoor,
    bool hasPoolOutdoor,
    bool isBeachfront, {
    /// Admin tooling keeps ✓/✗ so moderation sees full checklist; guests see only selected perks.
    bool showUncheckedBooleanFeatures = false,
  }) {
    final loc = AppLocalizations.of(context)!;

    final features = <Widget>[
      _featureItem("${loc.roomCount}: $roomCount"),
      _featureItem("${loc.masterRoomCount}: $masterRoomCount"),
      _featureItem("${loc.bathroomCount}: $bathroomCount"),
      _featureItem("${loc.propertySize}: $size"),
      _featureItem("${loc.parkingCount}: $parkingCount"),
    ];

    void addBool(bool flag, String labelArEn) {
      if (showUncheckedBooleanFeatures) {
        features.add(
          _featureItem("$labelArEn: ${flag ? "✓" : "✗"}"),
        );
      } else if (flag) {
        features.add(_featureItem("$labelArEn: ✓"));
      }
    }

    addBool(hasElevator, loc.hasElevator);
    addBool(hasCentralAC, loc.hasCentralAC);
    addBool(hasSplitAC, loc.hasSplitAC);
    addBool(hasMaidRoom, loc.hasMaidRoom);
    addBool(hasDriverRoom, loc.hasDriverRoom);
    addBool(hasLaundryRoom, loc.hasLaundryRoom);
    addBool(hasGarden, loc.hasGarden);
    addBool(hasPoolIndoor, loc.hasPoolIndoor);
    addBool(hasPoolOutdoor, loc.hasPoolOutdoor);
    addBool(isBeachfront, loc.isBeachfront);

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
      child: SelectableText(
        text,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildFooter(BuildContext context, Timestamp createdAt) {
    final loc = AppLocalizations.of(context)!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: SelectableText(
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
    final line = '$label: $value';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        label: line,
        excludeSemantics: true,
        container: true,
        child: SelectableText(
          line,
          style: const TextStyle(fontSize: 16),
        ),
      ),
    );
  }
}

/// Admin-only section on property details (moderation + owner contact).
class PropertyDetailsAdminControls extends StatelessWidget {
  const PropertyDetailsAdminControls({
    super.key,
    required this.ownerName,
    required this.ownerPhone,
    required this.propertyId,
    required this.ownerId,
  });

  final String ownerName;
  final String ownerPhone;
  final String propertyId;
  final String ownerId;

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

  @override
  Widget build(BuildContext context) {
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
}

class _AiSuggestionMetrics {
  const _AiSuggestionMetrics({
    required this.viewsCount,
    required this.inquiriesCount,
    required this.loadedAt,
  });

  final int? viewsCount;
  final int? inquiriesCount;
  final DateTime loadedAt;
}

class _FeaturePlan {
  const _FeaturePlan({
    required this.durationDays,
    required this.priceKwd,
    required this.labelAr,
  });

  final int durationDays;
  final int priceKwd;
  final String labelAr;
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({
    required this.plan,
    required this.onTap,
    required this.primary,
    this.highlight = false,
  });

  final _FeaturePlan plan;
  final VoidCallback onTap;
  final Color primary;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final border = highlight ? primary.withValues(alpha: 0.55) : Colors.black12;
    final bg = highlight
        ? Color.alphaBlend(primary.withValues(alpha: 0.06), Colors.white)
        : Colors.white;
    final badgeBg = highlight ? primary : Colors.black.withValues(alpha: 0.06);
    final badgeFg = highlight ? Colors.white : Colors.black87;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border, width: highlight ? 1.3 : 1.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    plan.labelAr,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${plan.priceKwd} د.ك',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                highlight ? 'أفضل قيمة' : 'اختر',
                style: TextStyle(
                  color: badgeFg,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiSuggestionCard extends StatelessWidget {
  const _AiSuggestionCard({
    required this.title,
    required this.message,
    required this.buttonText,
    required this.onPressed,
    this.buttonSubtitle,
    this.accentOverride,
    this.urgent = false,
    this.isLoading = false,
  });

  final String title;
  final String message;
  final String buttonText;
  final String? buttonSubtitle;
  final Color? accentOverride;
  final VoidCallback? onPressed;
  final bool urgent;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF101046);

    final Color accent =
        urgent ? const Color(0xFFE65100) : (accentOverride ?? primary);
    final Color iconBg = urgent
        ? const Color(0xFFFFE0B2)
        : primary.withValues(alpha: 0.12);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: urgent
            ? const Color(0xFFFFF3E0)
            : Color.alphaBlend(primary.withValues(alpha: 0.06), Colors.white),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: urgent ? 0.55 : 0.28)),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: urgent ? 0.16 : 0.10),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              urgent ? Icons.hourglass_bottom : Icons.auto_awesome,
              color: accent.withValues(alpha: 0.95),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  style: TextStyle(
                    height: 1.25,
                    color: Colors.black.withValues(alpha: urgent ? 0.84 : 0.72),
                    fontWeight: urgent ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: onPressed,
                    icon: isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.star, size: 18),
                    label: Text(
                      buttonText,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                if (buttonSubtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    buttonSubtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      color: Colors.black.withValues(
                        alpha: urgent ? 0.72 : 0.55,
                      ),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One Firestore write per open; skipped for admin preview so metrics stay user-facing.
class _RecordPropertyViewOnce extends StatefulWidget {
  final String propertyId;
  final String leadSource;
  final bool skipRecording;
  final String? captionTrackingId;
  final String? auctionLotId;
  final Widget child;

  const _RecordPropertyViewOnce({
    required this.propertyId,
    required this.leadSource,
    required this.skipRecording,
    this.captionTrackingId,
    this.auctionLotId,
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
        } catch (e, st) {
          debugPrint(
            'Error in _RecordPropertyViewOnceState caption area prefetch: $e\n$st',
          );
        }
        await CaptionClickLogService.logClick(
          captionId: cid,
          propertyId: widget.propertyId,
          area: area,
        );
      });
    }
    final lotFromAuction = widget.auctionLotId?.trim();
    if (lotFromAuction != null &&
        lotFromAuction.isNotEmpty &&
        !widget.skipRecording) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AuctionAnalyticsService.logAuctionViewed(lotId: lotFromAuction);
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Accessibility / SEO label for each photo (does not alter layout pixels).
String _carouselImageSemanticsLabel({
  required int pageIndexZeroBased,
  required int totalImages,
  required String listingSemanticCaption,
  required bool isArabic,
}) {
  final base = listingSemanticCaption.trim().isEmpty
      ? (isArabic ? 'إعلان عقاري' : 'property listing')
      : listingSemanticCaption.trim();
  if (totalImages <= 1) {
    return isArabic ? 'صورة الإعلان: $base' : 'Photo of listing: $base';
  }
  return isArabic
      ? 'صورة ${pageIndexZeroBased + 1} من $totalImages للعقار: $base'
      : 'Image ${pageIndexZeroBased + 1} of $totalImages: $base';
}

class _PropertyImageCarousel extends StatefulWidget {
  const _PropertyImageCarousel({
    required this.images,
    required this.height,
    required this.borderRadius,
    required this.memCacheWidth,
    required this.listingSemanticCaption,
    required this.isArabic,
  });

  final List<String> images;
  final double height;
  final double borderRadius;
  final int memCacheWidth;
  final String listingSemanticCaption;
  final bool isArabic;

  @override
  State<_PropertyImageCarousel> createState() => _PropertyImageCarouselState();
}

class _PropertyImageCarouselState extends State<_PropertyImageCarousel> {
  final PageController _controller = PageController();
  final ValueNotifier<int> _index = ValueNotifier<int>(0);
  final Set<String> _precached = <String>{};

  @override
  void initState() {
    super.initState();
    // Precache after first frame so context is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheAll());
  }

  @override
  void didUpdateWidget(covariant _PropertyImageCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.images, widget.images)) {
      // Keep index in bounds if the list changed.
      final len = widget.images.length;
      if (len <= 1) {
        _index.value = 0;
      } else if (_index.value >= len) {
        _index.value = 0;
        _controller.jumpToPage(0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _precacheAll());
    }
  }

  Future<void> _precacheAll() async {
    if (!mounted) return;
    // Only precache each URL once per widget lifetime.
    for (final url in widget.images) {
      if (url.isEmpty || _precached.contains(url)) continue;
      _precached.add(url);
      try {
        await precacheImage(CachedNetworkImageProvider(url), context);
      } catch (_) {
        // Ignore: network/caching issues should not break UI.
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _index.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    final showControls = images.length > 1;

    Widget dot({required bool active}) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        height: 7,
        width: active ? 18 : 7,
        decoration: BoxDecoration(
          color: active ? Colors.blueGrey.shade900 : Colors.blueGrey.shade300,
          borderRadius: BorderRadius.circular(999),
        ),
      );
    }

    // Keep the PageView stable; only counter/dots listen to [_index].
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: widget.height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: Stack(
              children: [
                PageView.builder(
                  controller: _controller,
                  itemCount: images.length,
                  onPageChanged: (i) => _index.value = i,
                  itemBuilder: (context, page) {
                    final url = images[page];
                    final semLabel = _carouselImageSemanticsLabel(
                      pageIndexZeroBased: page,
                      totalImages: images.length,
                      listingSemanticCaption: widget.listingSemanticCaption,
                      isArabic: widget.isArabic,
                    );
                    return RepaintBoundary(
                      child: Semantics(
                        container: true,
                        image: true,
                        excludeSemantics: true,
                        label: semLabel,
                        child: CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          memCacheWidth: widget.memCacheWidth,
                          maxWidthDiskCache: widget.memCacheWidth,
                          fadeInDuration: const Duration(milliseconds: 220),
                          fadeOutDuration: const Duration(milliseconds: 120),
                          placeholder: (_, __) => ColoredBox(
                            color: Colors.grey.shade300,
                            child: const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          ),
                          errorWidget: (_, __, ___) =>
                              ColoredBox(color: Colors.grey.shade300),
                        ),
                      ),
                    );
                  },
                ),
                if (showControls)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: ValueListenableBuilder<int>(
                      valueListenable: _index,
                      builder: (_, i, __) {
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder: (child, anim) =>
                              FadeTransition(opacity: anim, child: child),
                          child: Container(
                            key: ValueKey<int>(i),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${i + 1} / ${images.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (showControls) ...[
          const SizedBox(height: 10),
          ValueListenableBuilder<int>(
            valueListenable: _index,
            builder: (_, i, __) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List<Widget>.generate(
                  images.length,
                  (dotIndex) => dot(active: dotIndex == i),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
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

/// Shows timeout vs manual rejection copy from `public_lots` when status is `rejected`.
class _AuctionLotPublicRejectionStrip extends StatelessWidget {
  const _AuctionLotPublicRejectionStrip({
    required this.lotDocId,
    this.expectedAuctionId,
  });

  final String lotDocId;
  final String? expectedAuctionId;

  @override
  Widget build(BuildContext context) {
    final col = AuctionFirestorePaths.publicLots;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(col)
          .doc(lotDocId)
          .snapshots(),
      builder: (context, docSnap) {
        final ds = docSnap.data;
        if (ds == null || !ds.exists || ds.data() == null) {
          return const SizedBox.shrink();
        }
        final lot = PublicAuctionLot.fromFirestore(ds.id, ds.data()!);
        final exp = expectedAuctionId?.trim();
        if (exp != null && exp.isNotEmpty && lot.auctionId != exp) {
          return const SizedBox.shrink();
        }
        if (lot.displayStatus != 'rejected') {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: AuctionLotRejectionStrip(
            rejectionReason: lot.rejectionReason,
            dense: true,
          ),
        );
      },
    );
  }
}

/// Prompts the listing owner when the linked lot is in `pending_admin_review`.
class _SellerAuctionOutcomeEntry extends StatelessWidget {
  const _SellerAuctionOutcomeEntry({required this.lotId});

  final String lotId;

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AuctionFirestorePaths.publicLots)
          .doc(lotId)
          .snapshots(),
      builder: (context, s) {
        final d = s.data?.data();
        if (d == null) return const SizedBox.shrink();
        final status = d['status']?.toString() ?? '';
        if (status != 'pending_admin_review') {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Card(
            color: Colors.teal.shade50,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.teal.shade200),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.how_to_vote_outlined,
                        color: Colors.teal.shade800,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          isAr
                              ? 'مطلوب موافقتك على نتيجة المزاد'
                              : 'Your approval is required for the auction outcome',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.teal.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isAr
                        ? 'راجع أعلى مزايدة وقرّر القبول أو الرفض.'
                        : 'Review the highest bid and accept or reject.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              SellerAuctionApprovalPage(lotId: lotId),
                        ),
                      );
                    },
                    child: Text(isAr ? 'مراجعة' : 'Review'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PropertyVideoPreviewCard extends StatelessWidget {
  const _PropertyVideoPreviewCard({required this.videoUrl});

  final String videoUrl;

  static Widget _gradientPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.grey.shade800,
            Colors.grey.shade900,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final thumbUrl = VideoEmbedUrl.youtubeThumbnailUrl(videoUrl);

    return Material(
      color: Colors.grey.shade900,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => VideoPage(videoUrl: videoUrl),
            ),
          );
        },
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              if (thumbUrl != null)
                CachedNetworkImage(
                  imageUrl: thumbUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => ColoredBox(
                    color: Colors.grey.shade900,
                    child: const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  errorWidget: (_, _, _) => _gradientPlaceholder(),
                )
              else
                _gradientPlaceholder(),
              ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
              Icon(
                Icons.play_circle_filled,
                size: 68,
                color: Colors.white.withValues(alpha: 0.92),
              ),
              Positioned(
                bottom: 10,
                child: Text(
                  isAr ? 'مشاهدة الفيديو' : 'Watch video',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    shadows: const [
                      Shadow(
                        blurRadius: 8,
                        color: Colors.black54,
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

/// Loads [PublicAuctionLot] only from `public_lots/{lotDocId}` (must match [PropertyDetailsPage.auctionLotId]).
class _AuctionRegistrationForLot extends StatelessWidget {
  const _AuctionRegistrationForLot({
    required this.lotDocId,
    required this.listingPrice,
    this.expectedAuctionId,
  });

  final String lotDocId;
  final double listingPrice;
  final String? expectedAuctionId;

  @override
  Widget build(BuildContext context) {
    final col = AuctionFirestorePaths.publicLots;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(col)
          .doc(lotDocId)
          .snapshots(),
      builder: (context, docSnap) {
        if (!docSnap.hasData) return const SizedBox.shrink();
        final ds = docSnap.data!;
        if (!ds.exists || ds.data() == null) {
          return const SizedBox.shrink();
        }
        final lot = PublicAuctionLot.fromFirestore(ds.id, ds.data()!);
        final exp = expectedAuctionId?.trim();
        if (exp != null && exp.isNotEmpty && lot.auctionId != exp) {
          return const SizedBox.shrink();
        }
        return Column(
          children: [
            const SizedBox(height: 12),
            AuctionRegistrationStatusWidget(
              lot: lot,
              listingPrice: listingPrice,
            ),
          ],
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

/// Deterministic yield / ROI card — Phase 1.
///
/// Shown only for `serviceType == 'sale'` listings. Consumes whatever is
/// cached on the property doc (`data['roi']`) and, if missing, triggers a
/// single backend compute via [AiBrainService.computeRoi]. When the backend
/// returns null we display an honest "no data" state — we never guess.
///
/// A source badge (owner vs market comparables) sits next to the yield so
/// buyers can judge how trustworthy the number is.
class _YieldCard extends StatefulWidget {
  const _YieldCard({
    required this.propertyId,
    required this.cachedRoi,
    required this.isArabic,
  });

  final String propertyId;
  final Map<String, dynamic>? cachedRoi;
  final bool isArabic;

  @override
  State<_YieldCard> createState() => _YieldCardState();
}

class _YieldCardState extends State<_YieldCard> {
  Map<String, dynamic>? _roi;
  bool _loading = false;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    _roi = widget.cachedRoi;
    // If no cache is present we kick off a single compute request on the
    // next frame. We deliberately avoid retry / polling — the 7-day TTL on
    // the backend means most views hit warm cache anyway.
    if (_roi == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetch();
      });
    }
  }

  Future<void> _fetch() async {
    if (_loading || _tried) return;
    setState(() => _loading = true);
    Map<String, dynamic>? result;
    try {
      result = await AiBrainService().computeRoi(propertyId: widget.propertyId);
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    setState(() {
      _roi = result;
      _loading = false;
      _tried = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final title = isAr ? 'تقدير العائد' : 'Estimated yield';

    if (_loading) {
      return _YieldShell(
        title: title,
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(isAr ? 'جاري الحساب…' : 'Calculating…'),
          ],
        ),
      );
    }

    if (_roi == null) {
      return _YieldShell(
        title: title,
        child: Text(
          isAr
              ? 'ما عندي بيانات كافية لحساب العائد لهذا العقار بشكل دقيق.'
              : 'Not enough data to calculate a reliable yield for this listing.',
          style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
        ),
      );
    }

    final yieldPercent = (_roi!['yieldPercent'] as num?)?.toDouble();
    final payback = (_roi!['paybackYears'] as num?)?.toDouble();
    final annual = (_roi!['annualIncomeKwd'] as num?)?.toDouble();
    final source = (_roi!['source'] ?? '').toString();
    final sampleSize = (_roi!['comparableCount'] as num?)?.toInt();

    final badgeLabel = source == 'owner'
        ? (isAr ? 'من بيانات المالك' : 'Owner-provided')
        : (isAr ? 'من السوق' : 'From market');
    final badgeColor = source == 'owner'
        ? Colors.blue.shade50
        : Colors.green.shade50;
    final badgeBorder = source == 'owner'
        ? Colors.blue.shade300
        : Colors.green.shade300;

    return _YieldShell(
      title: title,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: badgeColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: badgeBorder),
        ),
        child: Text(
          source == 'comparables' && sampleSize != null
              ? '$badgeLabel · $sampleSize'
              : badgeLabel,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _YieldMetric(
                  label: isAr ? 'العائد السنوي' : 'Gross yield',
                  value: yieldPercent != null
                      ? '${yieldPercent.toStringAsFixed(1)}%'
                      : '—',
                ),
              ),
              Expanded(
                child: _YieldMetric(
                  label: isAr ? 'فترة الاسترداد' : 'Payback',
                  value: payback != null
                      ? (isAr
                          ? '${payback.toStringAsFixed(1)} سنة'
                          : '${payback.toStringAsFixed(1)} yrs')
                      : '—',
                ),
              ),
            ],
          ),
          if (annual != null) ...[
            const SizedBox(height: 6),
            Text(
              isAr
                  ? 'الدخل السنوي المتوقع: ${annual.toStringAsFixed(0)} د.ك'
                  : 'Expected annual income: KWD ${annual.toStringAsFixed(0)}',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            isAr
                ? 'تقدير استرشادي — قد يختلف حسب الإشغال والصيانة.'
                : 'Indicative estimate — varies with occupancy and maintenance.',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

class _YieldShell extends StatelessWidget {
  const _YieldShell({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _YieldMetric extends StatelessWidget {
  const _YieldMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
