// lib/pages/add_property_page.dart

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';

// الخرائط الرسمية
import 'package:aqarai_app/data/governorates_data_ar.dart';
import 'package:aqarai_app/data/governorates_data_en.dart';

// 🔥 التحويل الرسمي AR → EN (الاستخدام داخل صفحة الإضافة)
import 'package:aqarai_app/data/ar_to_en_mapping.dart';

import 'package:aqarai_app/pages/my_ads_page.dart';
import 'package:aqarai_app/services/seller_radar_service.dart';
import 'package:aqarai_app/services/user_ban_service.dart';

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

  int? _interestedBuyersCount;

  File? pickedImage;
  bool _loading = false;

  // Controllers
  final fullNameController = TextEditingController();
  final ownerPhoneController = TextEditingController();

  final descriptionController = TextEditingController();
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

  // ✅ توليد Code ثابت وآمن (دائم)
  String _code(String s) {
    var v = s.trim().toLowerCase();
    v = v.replaceAll(RegExp(r'\s+'), '_');
    v = v.replaceAll('-', '_');
    v = v.replaceAll(RegExp(r'[^a-z0-9_]+'), '');
    v = v.replaceAll(RegExp(r'_+'), '_');
    v = v.replaceAll(RegExp(r'^_+|_+$'), '');
    return v;
  }

  @override
  void initState() {
    super.initState();
    _termsLinkTap = TapGestureRecognizer()
      ..onTap = () {
        if (!mounted) return;
        _showTermsDialog(context, AppLocalizations.of(context)!);
      };
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _updateInterestedBuyersCount());
  }

  @override
  void dispose() {
    fullNameController.dispose();
    ownerPhoneController.dispose();
    descriptionController.dispose();
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

  String _normalizeDigits(String input) {
    const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const persian = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

    var s = input.trim();
    for (var i = 0; i < 10; i++) {
      s = s.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
    }
    return s.replaceAll(RegExp(r'[^\d\.\-]'), '');
  }

  int _parseInt(String text) => int.tryParse(_normalizeDigits(text)) ?? 0;
  double _parseDouble(String text) =>
      double.tryParse(_normalizeDigits(text)) ?? 0;

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      setState(() => pickedImage = File(picked.path));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showTermsDialog(BuildContext context, AppLocalizations loc) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.addPropertyTermsDialogTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              loc.addPropertyTermsDialogBody,
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(loc.addPropertyTermsDialogClose),
          ),
        ],
      ),
    );
  }

  Future<void> _updateInterestedBuyersCount() async {
    if (selectedArea == null || selectedPropertyType == null) {
      if (mounted) setState(() => _interestedBuyersCount = null);
      return;
    }
    final areaAr = selectedArea!;
    final areaEn = areaArToEn[areaAr] ?? '';
    final areaCode = _code(areaEn.isNotEmpty ? areaEn : areaAr);
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

    if (_normalizeDigits(sizeController.text).isEmpty) {
      _toast(loc.propertySize);
      return false;
    }
    if (_normalizeDigits(priceController.text).isEmpty) {
      _toast(loc.propertyPrice);
      return false;
    }
    if (!_acceptedTerms) {
      _toast(loc.addPropertyTermsMustAccept);
      return false;
    }

    return true;
  }

  Future<String?> _uploadImage(String docId) async {
    if (pickedImage == null) return null;

    final ref = FirebaseStorage.instance.ref().child(
      "properties/$docId/${DateTime.now().millisecondsSinceEpoch}.jpg",
    );

    await ref.putFile(pickedImage!);
    return ref.getDownloadURL();
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

    try {
      setState(() => _loading = true);

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
      final governorateCode = _code(govEn.isNotEmpty ? govEn : govAr);
      final areaCode = _code(areaEn.isNotEmpty ? areaEn : areaAr);

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

        "roomCount": _parseInt(roomCountController.text),
        "masterRoomCount": _parseInt(masterRoomCountController.text),
        "bathroomCount": _parseInt(bathroomCountController.text),
        "parkingCount": _parseInt(parkingCountController.text),
        "size": _parseDouble(sizeController.text),
        "price": _parseDouble(priceController.text),

        "hasElevator": hasElevator,
        "hasCentralAC": hasCentralAC,
        "hasSplitAC": hasSplitAC,
        "hasMaidRoom": hasMaidRoom,
        "hasDriverRoom": hasDriverRoom,
        "hasLaundryRoom": hasLaundryRoom,
        "hasGarden": hasGarden,

        "images": [],
        "imagesApproved": false,
        "approved": false,
        "status": "active",

        // Phase 1: تمييز الشاليه عن العادي (بدون حجوزات في التطبيق بعد)
        "listingCategory":
            selectedPropertyType == 'chalet' ? 'chalet' : 'normal',
        "hiddenFromPublic": false,
        "closeRequestSubmitted": false,

        "createdAt": FieldValue.serverTimestamp(),
        "updatedAt": FieldValue.serverTimestamp(),
      };

      final docRef = await firestore.collection("properties").add(data);

      if (pickedImage != null) {
        final url = await _uploadImage(docRef.id);
        if (url != null) {
          await docRef.update({
            "images": [url],
          });
        }
      }

      await docRef.update({
        "id": docRef.id,
        "updatedAt": FieldValue.serverTimestamp(),
      });

      if (mounted) _toast(AppLocalizations.of(context)!.propertySentForReview);

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MyAdsPage()),
      );
    } catch (e) {
      if (mounted) _toast('${AppLocalizations.of(context)!.errorLabel}: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openAreaSearchSheet() {
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final data = isArabic ? governoratesAndAreasAr : governoratesAndAreasEn;

    final List<Map<String, String>> allAreas = [];
    data.forEach((gov, areas) {
      for (final area in areas) {
        allAreas.add({"governorate": gov, "area": area});
      }
    });

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        String query = "";

        return StatefulBuilder(
          builder: (context, setModalState) {
            final filtered = allAreas.where((item) {
              final a = item["area"]!.toLowerCase();
              final g = item["governorate"]!.toLowerCase();
              final q = query.toLowerCase();
              return a.contains(q) || g.contains(q);
            }).toList();

            return Padding(
              padding: MediaQuery.of(context).viewInsets,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: isArabic ? "ابحث عن المنطقة" : "Search area",
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onChanged: (v) => setModalState(() => query = v),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final item = filtered[i];
                        return ListTile(
                          title: Text(item["area"]!),
                          subtitle: Text(item["governorate"]!),
                          onTap: () {
                            if (!mounted) return;
                            setState(() {
                              selectedGovernorate = item["governorate"];
                              selectedArea = item["area"];
                            });
                            Navigator.pop(context);
                            WidgetsBinding.instance.addPostFrameCallback(
                                (_) => _updateInterestedBuyersCount());
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
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
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              if (pickedImage != null && pickedImage!.existsSync())
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Image.file(pickedImage!, height: 200),
                ),

              ElevatedButton.icon(
                onPressed: _loading ? null : _pickImage,
                icon: const Icon(Icons.image),
                label: Text(loc.choosePropertyImage),
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
                            (_) => _updateInterestedBuyersCount());
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
                            (_) => _updateInterestedBuyersCount());
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
                            (_) => _updateInterestedBuyersCount());
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
                  setState(() => selectedPropertyType = v);
                  WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _updateInterestedBuyersCount());
                },
              ),

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

              const SizedBox(height: 22),

              if (_interestedBuyersCount != null &&
                  _interestedBuyersCount! > 0)
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

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_loading || !_acceptedTerms)
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
    );
  }
}
