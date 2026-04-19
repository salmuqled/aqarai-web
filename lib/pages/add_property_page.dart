// lib/pages/add_property_page.dart

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

// 🔥 التحويل الرسمي AR → EN (الاستخدام داخل صفحة الإضافة)
import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/data/kuwait_areas.dart';

import 'package:aqarai_app/pages/my_ads_page.dart';
import 'package:aqarai_app/pages/terms_conditions_page.dart';
import 'package:aqarai_app/services/image_processing_service.dart';
import 'package:aqarai_app/services/property_listing_image_service.dart';
import 'package:aqarai_app/utils/video_embed_url.dart';
import 'package:aqarai_app/services/seller_radar_service.dart';
import 'package:aqarai_app/services/user_ban_service.dart';
import 'package:aqarai_app/utils/property_form_parsing.dart';
import 'package:aqarai_app/utils/property_price_type.dart';
import 'package:aqarai_app/widgets/property_area_search_sheet.dart';
import 'package:aqarai_app/models/listing_enums.dart';

class AddPropertyPage extends StatefulWidget {
  const AddPropertyPage({super.key});

  @override
  State<AddPropertyPage> createState() => _AddPropertyPageState();
}

class _AddPropertyPageState extends State<AddPropertyPage> {
  final FirebaseFirestore firestore = FirebaseFirestore.instance;

  String? selectedGovernorate;
  String? selectedArea;
  String? selectedPropertyType;
  String selectedServiceType = 'sale';
  String selectedChaletMode = ChaletMode.daily;

  int? _interestedBuyersCount;

  final List<ProcessedListingPhoto> _listingPhotos = [];
  bool _processingImages = false;
  int _processingDone = 0;
  int _processingTotal = 0;
  bool _loading = false;

  // Controllers
  final fullNameController = TextEditingController();
  final ownerPhoneController = TextEditingController();

  final descriptionController = TextEditingController();
  final videoUrlController = TextEditingController();
  final roomCountController = TextEditingController();
  final masterRoomCountController = TextEditingController();
  final bathroomCountController = TextEditingController();
  final parkingCountController = TextEditingController();
  final sizeController = TextEditingController();
  final priceController = TextEditingController();

  // Extra features
  bool hasElevator = false;
  bool hasCentralAC = false;
  bool hasSplitAC = false;
  bool hasMaidRoom = false;
  bool hasDriverRoom = false;
  bool hasLaundryRoom = false;
  bool hasGarden = false;

  bool _acceptedTerms = false;

  late final TapGestureRecognizer _termsLinkTap;

  String? _lastLocaleCode;

  @override
  void initState() {
    super.initState();
    _termsLinkTap = TapGestureRecognizer()
      ..onTap = () {
        if (!mounted) return;
        _openTermsFullPage();
      };
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _updateInterestedBuyersCount(),
    );
  }

  @override
  void dispose() {
    fullNameController.dispose();
    ownerPhoneController.dispose();
    descriptionController.dispose();
    videoUrlController.dispose();
    roomCountController.dispose();
    masterRoomCountController.dispose();
    bathroomCountController.dispose();
    parkingCountController.dispose();
    sizeController.dispose();
    priceController.dispose();
    _termsLinkTap.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final localeCode = Localizations.localeOf(context).languageCode;

    if (_lastLocaleCode != null && _lastLocaleCode != localeCode) {
      selectedGovernorate = null;
      selectedArea = null;
      selectedPropertyType = null;
    }

    _lastLocaleCode = localeCode;

    const allowedValues = <String>{
      'apartment',
      'house',
      'building',
      'land',
      'industrialLand',
      'shop',
      'office',
      'chalet',
    };

    if (selectedPropertyType != null &&
        !allowedValues.contains(selectedPropertyType)) {
      selectedPropertyType = null;
    }
  }

  Future<void> _pickImages() async {
    if (_loading || _processingImages) return;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final remaining =
        ImageProcessingService.maxImages - _listingPhotos.length;
    if (remaining <= 0) {
      _toast(isAr ? 'الحد الأقصى 10 صور' : 'Maximum 10 photos.');
      return;
    }

    final pick =
        await ImageProcessingService.pickImages(maxSelectable: remaining);
    if (pick == null || pick.files.isEmpty) return;

    setState(() {
      _processingImages = true;
      _processingDone = 0;
      _processingTotal = pick.files.length;
    });
    try {
      final processed =
          await ImageProcessingService.processListingPhotosWithProgress(
        pick.files,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _processingDone = done;
            _processingTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _listingPhotos.addAll(processed);
        _processingImages = false;
        _processingDone = 0;
        _processingTotal = 0;
      });
      if (pick.truncatedFromSelection) {
        _toast(
          isAr
              ? 'تمت إضافة أول $remaining صور فقط (الحد 10).'
              : 'Only the first $remaining photos were added (max 10).',
        );
      }
    } catch (e, st) {
      debugPrint('[AddProperty] Image processing failed: $e\n$st');
      if (mounted) {
        setState(() {
          _processingImages = false;
          _processingDone = 0;
          _processingTotal = 0;
        });
        _toast(
          isAr
              ? 'تعذر معالجة الصور. حاول مجدداً.'
              : 'Could not process images. Try again.',
        );
      }
    }
  }

  void _removePickedImageAt(int index) {
    if (_loading || _processingImages) return;
    setState(() => _listingPhotos.removeAt(index));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showPublishSuccessSnackBar(AppLocalizations loc) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        duration: const Duration(milliseconds: 2600),
        dismissDirection: DismissDirection.horizontal,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        backgroundColor: AppColors.navy.withValues(alpha: 0.85),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.check_circle_rounded,
              size: 24,
              color: Colors.white,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                loc.publishSuccessBlessing,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
      snackBarAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 380),
        reverseDuration: Duration(milliseconds: 300),
      ),
    );
  }

  /// Single source of truth: top-level service intent is sale.
  bool isSaleListing() => selectedServiceType == 'sale';

  /// Chalet offered as daily booking (never apply sale-style KWD ×1000 heuristic).
  bool isChaletDailyBooking() =>
      selectedPropertyType == 'chalet' &&
      selectedChaletMode == ChaletMode.daily;

  /// When state is missing or not one of the known UI values, skip auto-normalization (fail closed).
  bool _priceNormalizationStateIsDefensible() {
    if (selectedPropertyType == null || selectedPropertyType!.trim().isEmpty) {
      return false;
    }
    if (selectedServiceType.trim().isEmpty) {
      return false;
    }
    const knownServiceTypes = {'sale', 'rent', 'exchange'};
    if (!knownServiceTypes.contains(selectedServiceType)) {
      return false;
    }
    if (selectedPropertyType == 'chalet') {
      const knownChaletModes = {
        ChaletMode.daily,
        ChaletMode.monthly,
        ChaletMode.sale,
      };
      if (!knownChaletModes.contains(selectedChaletMode)) {
        return false;
      }
    }
    return true;
  }

  /// Sale-only auto-normalization (e.g. 950 → 950000). Skipped for rent/exchange, chalet daily booking, and unsafe state.
  ({double price, bool priceAutoCorrected}) _computeListingPrice() {
    var price = parsePropertyDouble(priceController.text);
    var priceAutoCorrected = false;

    if (!_priceNormalizationStateIsDefensible()) {
      return (price: price, priceAutoCorrected: false);
    }

    if (isSaleListing() && !isChaletDailyBooking()) {
      if (price >= 100 && price < 10000) {
        price *= 1000;
        priceAutoCorrected = true;
      }
    }
    return (price: price, priceAutoCorrected: priceAutoCorrected);
  }

  /// Same resolution as [AqarSearchBox] / chalet search: canonical [kuwaitAreas]
  /// code when possible, else [propertyLocationCode] slug.
  String _resolvedAreaCode(String areaAr, String areaEn) {
    final String rawInput = areaAr.isNotEmpty
        ? areaAr
        : (areaEn.isNotEmpty ? areaEn : '');
    return getUnifiedAreaCode(
      rawInput,
      fallbackSlugSource: areaEn.isNotEmpty ? areaEn : areaAr,
    );
  }

  void _openTermsFullPage() {
    if (!mounted) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const TermsConditionsPage()),
    );
  }

  Future<void> _updateInterestedBuyersCount() async {
    if (selectedArea == null || selectedPropertyType == null) {
      if (mounted) setState(() => _interestedBuyersCount = null);
      return;
    }
    final areaAr = selectedArea!;
    final areaEn = areaArToEn[areaAr] ?? '';
    final areaCode = _resolvedAreaCode(areaAr, areaEn);
    try {
      final count = await SellerRadarService().getInterestedBuyersCount(
        areaCode: areaCode,
        type: selectedPropertyType!,
        serviceType: selectedServiceType,
      );
      if (mounted) setState(() => _interestedBuyersCount = count);
    } catch (_) {
      if (mounted) setState(() => _interestedBuyersCount = null);
    }
  }

  bool _validate(AppLocalizations loc) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    if (fullNameController.text.trim().isEmpty) {
      _toast("يرجى كتابة اسم المالك");
      return false;
    }
    if (ownerPhoneController.text.trim().isEmpty) {
      _toast("يرجى كتابة رقم المالك");
      return false;
    }
    if (selectedPropertyType == null) {
      _toast(loc.propertyType);
      return false;
    }
    if (selectedGovernorate == null || selectedArea == null) {
      _toast(loc.selectGovernorateAndArea);
      return false;
    }

    if (normalizeDigitsForPropertyForm(sizeController.text).isEmpty) {
      _toast(loc.propertySize);
      return false;
    }
    if (normalizeDigitsForPropertyForm(priceController.text).isEmpty) {
      _toast(loc.propertyPrice);
      return false;
    }
    final parsedPrice = parsePropertyDouble(priceController.text);
    if (!parsedPrice.isFinite || parsedPrice <= 0) {
      _toast(
        isAr ? 'السعر يجب أن يكون رقماً أكبر من صفر.' : 'Price must be a number greater than zero.',
      );
      return false;
    }
    if (!_acceptedTerms) {
      _toast(loc.addPropertyTermsMustAccept);
      return false;
    }

    if (_listingPhotos.isEmpty) {
      _toast(
        isAr
            ? 'صورة العقار مطلوبة قبل النشر.'
            : 'A property photo is required before publishing.',
      );
      return false;
    }
    if (_listingPhotos.length > ImageProcessingService.maxImages) {
      _toast(
        isAr
            ? 'الحد الأقصى 10 صور.'
            : 'Maximum 10 photos.',
      );
      return false;
    }
    try {
      for (final p in _listingPhotos) {
        if (!p.full.existsSync() ||
            p.full.lengthSync() <= 0 ||
            !p.thumbnail.existsSync() ||
            p.thumbnail.lengthSync() <= 0) {
          _toast(
            isAr ? 'ملف الصورة غير صالح.' : 'The image file is not valid.',
          );
          return false;
        }
      }
    } on FileSystemException {
      _toast(
        isAr
            ? 'تعذر قراءة الصورة. اختر صورة أخرى.'
            : 'Could not read the image. Pick another photo.',
      );
      return false;
    }

    final videoTrim = videoUrlController.text.trim();
    if (videoTrim.isNotEmpty && !VideoEmbedUrl.isEmptyOrValid(videoTrim)) {
      _toast(
        isAr
            ? 'رابط الفيديو غير صالح (يُقبل يوتيوب أو فيميو فقط).'
            : 'Invalid video link (YouTube or Vimeo only).',
      );
      return false;
    }

    return true;
  }

  Future<User?> _ensureSignedIn() async {
    final auth = FirebaseAuth.instance;

    if (auth.currentUser != null) return auth.currentUser;

    try {
      final cred = await auth.signInAnonymously();
      return cred.user;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveProperty() async {
    final loc = AppLocalizations.of(context)!;

    if (!_validate(loc)) return;

    DocumentReference<Map<String, dynamic>>? createdRef;

    try {
      setState(() => _loading = true);
      final isAr = Localizations.localeOf(context).languageCode == 'ar';

      final user = await _ensureSignedIn();
      if (user == null) {
        _toast("Sign-in failed");
        return;
      }

      if (await UserBanService.isCurrentUserBanned()) {
        if (mounted) {
          _toast(loc.cannotPostBanned);
        }
        return;
      }

      final govAr = selectedGovernorate ?? "";
      final areaAr = selectedArea ?? "";

      final govEn = governorateArToEn[govAr] ?? "";
      final areaEn = areaArToEn[areaAr] ?? "";

      // ✅ codes ثابتة للبحث (الأساس الجديد)
      final governorateCode = propertyLocationCode(
        govEn.isNotEmpty ? govEn : govAr,
      );
      final areaCode = _resolvedAreaCode(areaAr, areaEn);

      final listingPrice = _computeListingPrice();
      // Never persist non-positive or non-finite price (defense in depth after _validate).
      if (!listingPrice.price.isFinite || listingPrice.price <= 0) {
        if (mounted) {
          _toast(
            isAr ? 'السعر غير صالح.' : 'Invalid price.',
          );
        }
        return;
      }

      final priceType = PropertyPriceType.forNewListing(
        propertyType: selectedPropertyType!,
        serviceType: selectedServiceType,
      );

      // Matches `searchDailyProperties` filters (`daily` | `monthly`); chalet `sale`
      // mode must not be stored as `monthly`. Non-chalet follows `priceType`.
      final String rentalTypeForSave = selectedPropertyType == 'chalet'
          ? switch (selectedChaletMode) {
              ChaletMode.daily => 'daily',
              ChaletMode.monthly => 'monthly',
              ChaletMode.sale => 'sale',
              _ => 'daily',
            }
          : switch (priceType) {
              'daily' => 'daily',
              'monthly' => 'monthly',
              'yearly' => 'monthly',
              _ => 'full',
            };

      final data = {
        "ownerId": user.uid,
        "fullName": fullNameController.text.trim(),
        "ownerPhone": ownerPhoneController.text.trim(),
        "isAnonymous": user.isAnonymous,

        // BOTH LANGUAGES (عرض)
        "governorateAr": govAr,
        "governorateEn": govEn,
        "areaAr": areaAr,
        "areaEn": areaEn,

        // ✅ CODES (بحث دائم)
        "governorateCode": governorateCode,
        "areaCode": areaCode,

        "type": selectedPropertyType,
        "serviceType": selectedServiceType,

        "description": descriptionController.text.trim(),

        "roomCount": parsePropertyInt(roomCountController.text),
        "masterRoomCount": parsePropertyInt(masterRoomCountController.text),
        "bathroomCount": parsePropertyInt(bathroomCountController.text),
        "parkingCount": parsePropertyInt(parkingCountController.text),
        "size": parsePropertyDouble(sizeController.text),
        "price": listingPrice.price,
        "priceType": priceType,
        if (listingPrice.priceAutoCorrected) "priceAutoCorrected": true,

        "hasElevator": hasElevator,
        "hasCentralAC": hasCentralAC,
        "hasSplitAC": hasSplitAC,
        "hasMaidRoom": hasMaidRoom,
        "hasDriverRoom": hasDriverRoom,
        "hasLaundryRoom": hasLaundryRoom,
        "hasGarden": hasGarden,

        if (videoUrlController.text.trim().isNotEmpty)
          "videoUrl": videoUrlController.text.trim(),

        "images": [],
        "hasImage": false,
        "imagesApproved": false,
        "approved": false,
        "sold": false,
        "status": ListingStatus.pendingUpload,
        "isActive": true,

        // Phase 1: listingCategory tracks `type` for rules + queries (type is source for chalet).
        "listingCategory": listingCategoryForPropertyType(selectedPropertyType),
        if (selectedPropertyType == 'chalet') "chaletMode": selectedChaletMode,
        "rentalType": rentalTypeForSave,
        "hiddenFromPublic": false,
        "closeRequestSubmitted": false,

        "createdAt": FieldValue.serverTimestamp(),
        "updatedAt": FieldValue.serverTimestamp(),
      };

      createdRef = await firestore.collection("properties").add(data);
      await createdRef.get();
      if (kDebugMode) {
        debugPrint(
          '[AddProperty] created propertyId=${createdRef.id} '
          'status=${ListingStatus.pendingUpload} hasImage=false images=0 thumbnails=0 approved=false',
        );
      }

      final userProfile = <String, dynamic>{
        'name': fullNameController.text.trim(),
        'role': 'owner',
      };
      final phoneTrim = ownerPhoneController.text.trim();
      if (phoneTrim.isNotEmpty) {
        userProfile['phone'] = phoneTrim;
      }
      await firestore.collection('users').doc(user.uid).set(
            userProfile,
            SetOptions(merge: true),
          );

      var imageUploadCompleted = false;
      try {
        final batch =
            await PropertyListingImageService.uploadListingPhotosToStorage(
          propertyId: createdRef.id,
          photos: List<ProcessedListingPhoto>.from(_listingPhotos),
        );
        try {
          await PropertyListingImageService.applyUploadedImagesToProperty(
            propertyId: createdRef.id,
            fullUrls: batch.map((e) => e.fullUrl).toList(),
            thumbnailUrls: batch.map((e) => e.thumbUrl).toList(),
          );
          imageUploadCompleted = true;
          if (kDebugMode) {
            debugPrint(
              '[AddProperty] upload complete propertyId=${createdRef.id} '
              'status=${ListingStatus.active} hasImage=true '
              'images=${batch.length} thumbnails=${batch.length}',
            );
          }
          await ImageProcessingService.tryDeleteProcessedListingPhotos(
            _listingPhotos,
          );
        } catch (e, st) {
          debugPrint('[AddProperty] Firestore after upload failed: $e\n$st');
          for (final up in batch) {
            try {
              await up.fullRef.delete();
            } catch (_) {}
            try {
              await up.thumbRef.delete();
            } catch (_) {}
          }
          try {
            await createdRef.update({
              'id': createdRef.id,
              'updatedAt': FieldValue.serverTimestamp(),
            });
          } catch (_) {}
          if (mounted) {
            _toast(
              isAr
                  ? '${loc.errorLabel} (حفظ الصورة): $e'
                  : '${loc.errorLabel} (saving photo): $e',
            );
          }
        }
      } on FirebaseException catch (e, st) {
        debugPrint(
          '[AddProperty] Image upload FirebaseException ${e.code} ${e.message}\n$st',
        );
        try {
          await createdRef.update({
            'id': createdRef.id,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (_) {}
        if (mounted) {
          _toast(
            isAr
                ? '${loc.errorLabel}: ${e.code} — ${e.message ?? ""}\nافتح «إعلاناتي» ثم «إعادة رفع الصورة».'
                : '${loc.errorLabel}: [${e.code}] ${e.message ?? ""}\nUse My Ads → Retry upload.',
          );
        }
      } catch (e, st) {
        debugPrint('[AddProperty] Image upload failed: $e\n$st');
        try {
          await createdRef.update({
            'id': createdRef.id,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (_) {}
        if (mounted) {
          _toast(
            isAr
                ? 'تم حفظ العقار. أكمل من «إعلاناتي» باستخدام «إعادة رفع الصورة».\n$e'
                : 'Listing saved. Open My Ads and tap Retry upload.\n$e',
          );
        }
      }

      if (mounted && imageUploadCompleted) {
        _showPublishSuccessSnackBar(loc);
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MyAdsPage()),
      );
    } catch (e, st) {
      debugPrint('[AddProperty] Publish error: $e\n$st');
      if (createdRef != null) {
        try {
          await createdRef.delete();
        } catch (_) {}
      }
      if (mounted) {
        _toast('${loc.errorLabel}: $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openAreaSearchSheet() {
    showPropertyAreaSearchSheet(
      context,
      onAreaSelected: (governorate, area) {
        if (!mounted) return;
        setState(() {
          selectedGovernorate = governorate;
          selectedArea = area;
        });
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _updateInterestedBuyersCount(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final textDirection = isArabic ? TextDirection.rtl : TextDirection.ltr;

    return Directionality(
      textDirection: textDirection,
      child: Scaffold(
        appBar: AppBar(title: Text(loc.addProperty), centerTitle: true),
        body: AbsorbPointer(
          absorbing: _processingImages || _loading,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
              if (_processingImages)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _processingTotal > 0
                                  ? () {
                                      final pct = ((_processingDone /
                                                  _processingTotal) *
                                              100)
                                          .clamp(0, 100)
                                          .round();
                                      return isArabic
                                          ? 'جاري المعالجة $_processingDone / $_processingTotal ($pct٪)'
                                          : 'Processing $_processingDone / $_processingTotal ($pct%)';
                                    }()
                                  : (isArabic
                                      ? 'جاري تحسين الصور والصور المصغّرة…'
                                      : 'Optimizing photos & thumbnails…'),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_processingTotal > 0) ...[
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 6,
                            value: _processingTotal > 0
                                ? (_processingDone / _processingTotal)
                                    .clamp(0.0, 1.0)
                                : null,
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 8),
                        const LinearProgressIndicator(minHeight: 4),
                      ],
                    ],
                  ),
                ),

              if (!_processingImages &&
                  _listingPhotos.isEmpty &&
                  !_loading) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade400),
                    color: Colors.grey.shade50,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 40,
                        color: Colors.grey.shade600,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isArabic
                            ? 'أضف صورة واحدة على الأقل (حتى 10 صور)'
                            : 'Add at least one photo (up to 10)',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              if (_listingPhotos.isNotEmpty) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    isArabic
                        ? 'اسحب لإعادة الترتيب — الأولى هي غلاف الإعلان'
                        : 'Drag to reorder — first photo is the cover',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: _listingPhotos.length,
                  onReorder: (oldIndex, newIndex) {
                    if (_loading || _processingImages) return;
                    setState(() {
                      if (newIndex > oldIndex) newIndex -= 1;
                      final item = _listingPhotos.removeAt(oldIndex);
                      _listingPhotos.insert(newIndex, item);
                    });
                  },
                  itemBuilder: (context, i) {
                    final photo = _listingPhotos[i];
                    final f = photo.full;
                    return Card(
                      key: ValueKey('${f.path}_${photo.thumbnail.path}'),
                      margin: const EdgeInsets.only(bottom: 8),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        contentPadding: const EdgeInsetsDirectional.only(
                          start: 8,
                          end: 4,
                        ),
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: SizedBox(
                            width: 72,
                            height: 72,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                f,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                        title: Text(
                          i == 0
                              ? (isArabic ? 'غلاف' : 'Cover')
                              : (isArabic ? 'صورة ${i + 1}' : 'Photo ${i + 1}'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: i == 0
                            ? Text(
                                isArabic
                                    ? 'تظهر أولاً في القوائم والتفاصيل'
                                    : 'Shown first in lists & details',
                              )
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (i == 0)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(end: 6),
                                child: Icon(
                                  Icons.star_rounded,
                                  color: Colors.amber.shade800,
                                  size: 26,
                                ),
                              ),
                            IconButton(
                              tooltip: isArabic ? 'حذف' : 'Remove',
                              onPressed: _loading || _processingImages
                                  ? null
                                  : () => _removePickedImageAt(i),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 4),
              ],

              ElevatedButton.icon(
                onPressed: (_loading || _processingImages)
                    ? null
                    : _pickImages,
                icon: const Icon(Icons.image),
                label: Text(
                  isArabic
                      ? 'إضافة صور (${_listingPhotos.length}/${ImageProcessingService.maxImages})'
                      : 'Add photos (${_listingPhotos.length}/${ImageProcessingService.maxImages})',
                ),
              ),

              const SizedBox(height: 20),

              Row(
                children: [
                  Expanded(
                    child: RadioListTile<String>(
                      title: Text(
                        loc.forSale,
                        style: const TextStyle(fontSize: 14),
                      ),
                      value: 'sale',
                      groupValue: selectedServiceType,
                      onChanged: (v) {
                        setState(() => selectedServiceType = v!);
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _updateInterestedBuyersCount(),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      title: Text(
                        loc.forRent,
                        style: const TextStyle(fontSize: 14),
                      ),
                      value: 'rent',
                      groupValue: selectedServiceType,
                      onChanged: (v) {
                        setState(() => selectedServiceType = v!);
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _updateInterestedBuyersCount(),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      title: Text(
                        loc.forExchange,
                        style: const TextStyle(fontSize: 14),
                      ),
                      value: 'exchange',
                      groupValue: selectedServiceType,
                      onChanged: (v) {
                        setState(() => selectedServiceType = v!);
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _updateInterestedBuyersCount(),
                        );
                      },
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              DropdownButtonFormField<String>(
                decoration: InputDecoration(labelText: loc.propertyType),
                value: selectedPropertyType,
                items: [
                  DropdownMenuItem(
                    value: 'apartment',
                    child: Text(loc.propertyType_apartment),
                  ),
                  DropdownMenuItem(
                    value: 'house',
                    child: Text(loc.propertyType_house),
                  ),
                  DropdownMenuItem(
                    value: 'building',
                    child: Text(loc.propertyType_building),
                  ),
                  DropdownMenuItem(
                    value: 'land',
                    child: Text(loc.propertyType_land),
                  ),
                  DropdownMenuItem(
                    value: 'industrialLand',
                    child: Text(loc.propertyType_industrialLand),
                  ),
                  DropdownMenuItem(
                    value: 'shop',
                    child: Text(loc.propertyType_shop),
                  ),
                  DropdownMenuItem(
                    value: 'office',
                    child: Text(loc.propertyType_office),
                  ),
                  DropdownMenuItem(
                    value: 'chalet',
                    child: Text(loc.propertyType_chalet),
                  ),
                ],
                onChanged: (v) {
                  setState(() {
                    selectedPropertyType = v;
                    if (v == 'chalet') {
                      selectedChaletMode = ChaletMode.daily;
                    }
                  });
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _updateInterestedBuyersCount(),
                  );
                },
              ),

              if (selectedPropertyType == 'chalet') ...[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    Localizations.localeOf(context).languageCode == 'ar'
                        ? 'طريقة عرض الشاليه'
                        : 'How this chalet is offered',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                RadioListTile<String>(
                  dense: true,
                  title: Text(
                    Localizations.localeOf(context).languageCode == 'ar'
                        ? 'حجز يومي'
                        : 'Daily booking',
                  ),
                  value: ChaletMode.daily,
                  groupValue: selectedChaletMode,
                  onChanged: (v) => setState(() => selectedChaletMode = v!),
                ),
                RadioListTile<String>(
                  dense: true,
                  title: Text(
                    Localizations.localeOf(context).languageCode == 'ar'
                        ? 'إيجار شهري'
                        : 'Monthly rental',
                  ),
                  value: ChaletMode.monthly,
                  groupValue: selectedChaletMode,
                  onChanged: (v) => setState(() => selectedChaletMode = v!),
                ),
                RadioListTile<String>(
                  dense: true,
                  title: Text(
                    Localizations.localeOf(context).languageCode == 'ar'
                        ? 'للبيع'
                        : 'For sale',
                  ),
                  value: ChaletMode.sale,
                  groupValue: selectedChaletMode,
                  onChanged: (v) => setState(() => selectedChaletMode = v!),
                ),
              ],

              const SizedBox(height: 12),

              GestureDetector(
                onTap: _openAreaSearchSheet,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 18,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black26),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          selectedArea == null
                              ? loc.selectGovernorateAndArea
                              : "$selectedArea — $selectedGovernorate",
                          style: TextStyle(
                            color: selectedArea == null
                                ? Colors.black54
                                : Colors.black,
                          ),
                        ),
                      ),
                      const Icon(Icons.search),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              TextFormField(
                controller: fullNameController,
                decoration: const InputDecoration(
                  labelText: "اسم المالك بالكامل",
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 12),

              TextFormField(
                controller: ownerPhoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: "رقم المالك",
                  hintText: "مثال: 94442242",
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: sizeController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: loc.propertySize),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: priceController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: loc.propertyPrice),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: roomCountController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: loc.roomCount),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: masterRoomCountController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: loc.masterRoomCount,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: bathroomCountController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: loc.bathroomCount),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: parkingCountController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: loc.parkingCount),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              CheckboxListTile(
                title: Text(loc.hasElevator),
                value: hasElevator,
                onChanged: (v) => setState(() => hasElevator = v!),
              ),
              CheckboxListTile(
                title: Text(loc.hasCentralAC),
                value: hasCentralAC,
                onChanged: (v) => setState(() => hasCentralAC = v!),
              ),
              CheckboxListTile(
                title: Text(loc.hasSplitAC),
                value: hasSplitAC,
                onChanged: (v) => setState(() => hasSplitAC = v!),
              ),
              CheckboxListTile(
                title: Text(loc.hasMaidRoom),
                value: hasMaidRoom,
                onChanged: (v) => setState(() => hasMaidRoom = v!),
              ),
              CheckboxListTile(
                title: Text(loc.hasDriverRoom),
                value: hasDriverRoom,
                onChanged: (v) => setState(() => hasDriverRoom = v!),
              ),
              CheckboxListTile(
                title: Text(loc.hasLaundryRoom),
                value: hasLaundryRoom,
                onChanged: (v) => setState(() => hasLaundryRoom = v!),
              ),
              CheckboxListTile(
                title: Text(loc.hasGarden),
                value: hasGarden,
                onChanged: (v) => setState(() => hasGarden = v!),
              ),

              const SizedBox(height: 12),

              TextFormField(
                controller: descriptionController,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: loc.description,
                  border: const OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 12),

              TextFormField(
                controller: videoUrlController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: isArabic
                      ? 'رابط فيديو (يوتيوب أو فيميو فقط)'
                      : 'Video link (YouTube or Vimeo only)',
                  hintText: isArabic
                      ? 'اتركه فارغاً إن لم يكن لديك فيديو'
                      : 'Leave empty if you have no video',
                  border: const OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 22),

              if (_interestedBuyersCount != null && _interestedBuyersCount! > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '🔥 يوجد $_interestedBuyersCount مشتري يبحثون عن عقار مشابه الآن',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.orange.shade800,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),

              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: _acceptedTerms,
                      onChanged: _loading
                          ? null
                          : (v) => setState(() => _acceptedTerms = v ?? false),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text.rich(
                          TextSpan(
                            style: theme.textTheme.bodyMedium,
                            children: [
                              TextSpan(text: loc.addPropertyTermsLead),
                              TextSpan(
                                text: loc.addPropertyTermsLink,
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.underline,
                                ),
                                recognizer: _termsLinkTap,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: 12,
                  end: 8,
                  bottom: 8,
                ),
                child: Text(
                  loc.addPropertyTermsCommissionNotice,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade800,
                    height: 1.45,
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsetsDirectional.only(start: 8, bottom: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: _loading ? null : _openTermsFullPage,
                    child: Text(loc.addPropertyViewFullTerms),
                  ),
                ),
              ),

              if (_loading) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Center(
                    child: _PublishingLoadingBlock(
                      primaryColor: theme.colorScheme.primary,
                      isArabic: isArabic,
                    ),
                  ),
                ),
              ],

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_loading ||
                          _processingImages ||
                          !_acceptedTerms)
                      ? null
                      : _saveProperty,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _loading ? loc.publishing : "📌 ${loc.publishProperty}",
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
              ),
                ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Subtle pulse + fade-in while publishing (add property).
class _PublishingLoadingBlock extends StatefulWidget {
  const _PublishingLoadingBlock({
    required this.primaryColor,
    required this.isArabic,
  });

  final Color primaryColor;
  final bool isArabic;

  @override
  State<_PublishingLoadingBlock> createState() =>
      _PublishingLoadingBlockState();
}

class _PublishingLoadingBlockState extends State<_PublishingLoadingBlock>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _fade;
  late final Animation<double> _pulseScale;
  late final Animation<double> _fadeOpacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..forward();
    _pulseScale = Tween<double>(begin: 0.94, end: 1.0).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
    _fadeOpacity = CurvedAnimation(
      parent: _fade,
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return FadeTransition(
      opacity: _fadeOpacity,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          ScaleTransition(
            scale: _pulseScale,
            child: SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: widget.primaryColor,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            widget.isArabic
                ? 'جاري نشر العقار...'
                : 'Publishing your listing...',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.isArabic ? 'يرجى الانتظار' : 'Please wait',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }
}
