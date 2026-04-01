import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:aqarai_app/auth/login_page.dart';
import 'package:aqarai_app/config/auction_listing_fee.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/pages/auction_payment_page.dart';
import 'package:aqarai_app/services/auction/auction_request_service.dart';
import 'package:aqarai_app/services/user_ban_service.dart';
import 'package:aqarai_app/utils/property_form_parsing.dart';
import 'package:aqarai_app/widgets/property_area_search_sheet.dart';

/// Premium property-style form; writes to `auction_requests` (not `properties`).
class AuctionRequestPage extends StatefulWidget {
  const AuctionRequestPage({super.key});

  @override
  State<AuctionRequestPage> createState() => _AuctionRequestPageState();
}

class _AuctionRequestPageState extends State<AuctionRequestPage> {
  String? selectedGovernorate;
  String? selectedArea;
  String? selectedPropertyType;

  File? pickedImage;
  bool _loading = false;
  bool _showAdvanced = false;

  final descriptionController = TextEditingController();
  final roomCountController = TextEditingController();
  final masterRoomCountController = TextEditingController();
  final bathroomCountController = TextEditingController();
  final parkingCountController = TextEditingController();
  final sizeController = TextEditingController();
  final priceController = TextEditingController();

  bool hasElevator = false;
  bool hasCentralAC = false;
  bool hasSplitAC = false;
  bool hasMaidRoom = false;
  bool hasDriverRoom = false;
  bool hasLaundryRoom = false;
  bool hasGarden = false;

  static const String _acceptAny = 'موافق على أي سعر';
  static const String _acceptSlight = 'موافق على فرق بسيط';
  static const String _acceptNo = 'غير موافق';

  String _acceptLevel = _acceptSlight;

  bool _acceptedTerms = false;

  late final TapGestureRecognizer _termsLinkTap;

  String? _lastLocaleCode;

  @override
  void initState() {
    super.initState();
    _termsLinkTap = TapGestureRecognizer()
      ..onTap = () {
        if (!mounted) return;
        _showTermsDialog(context, AppLocalizations.of(context)!);
      };
  }

  @override
  void dispose() {
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

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      setState(() => pickedImage = File(picked.path));
    }
  }

  bool _hasImage() =>
      pickedImage != null && pickedImage!.existsSync();

  bool _validate(AppLocalizations loc) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.isAnonymous) {
      _toast(loc.auctionRequestSignInRequired);
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

    if (normalizeDigitsForPropertyForm(priceController.text).isEmpty) {
      _toast(loc.propertyPrice);
      return false;
    }
    if (descriptionController.text.trim().isEmpty) {
      _toast(loc.description);
      return false;
    }
    if (!_hasImage()) {
      _toast('يجب إضافة صورة واحدة على الأقل');
      return false;
    }
    if (!_acceptedTerms) {
      _toast(loc.addPropertyTermsMustAccept);
      return false;
    }

    return true;
  }

  void _maybeWarnWeakRequest() {
    var score = 0;
    if (_hasImage()) score += 40;
    if (descriptionController.text.trim().isNotEmpty) score += 20;
    if (parsePropertyInt(roomCountController.text) > 0) score += 10;
    if (parsePropertyInt(bathroomCountController.text) > 0) score += 10;
    if (parsePropertyDouble(sizeController.text) > 0) score += 20;

    if (score < 50 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'طلبك ضعيف، حاول تضيف تفاصيل أكثر لزيادة فرص المزايدة',
          ),
        ),
      );
    }
  }

  Future<void> _submitAuctionRequest() async {
    final loc = AppLocalizations.of(context)!;

    if (!_validate(loc)) return;

    _maybeWarnWeakRequest();

    try {
      setState(() => _loading = true);

      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.isAnonymous) {
        _toast(loc.auctionRequestSignInRequired);
        return;
      }

      if (await UserBanService.isCurrentUserBanned()) {
        if (mounted) _toast(loc.cannotPostBanned);
        return;
      }

      final govAr = selectedGovernorate ?? '';
      final areaAr = selectedArea ?? '';

      final govEn = governorateArToEn[govAr] ?? '';
      final areaEn = areaArToEn[areaAr] ?? '';

      final governorateCode =
          propertyLocationCode(govEn.isNotEmpty ? govEn : govAr);
      final areaCode = propertyLocationCode(areaEn.isNotEmpty ? areaEn : areaAr);

      final acceptLowerStartPrice = _acceptLevel != _acceptNo;

      final requestId = await AuctionRequestService.submitRequest(
        propertyType: selectedPropertyType!,
        governorateAr: govAr,
        governorateEn: govEn,
        areaAr: areaAr,
        areaEn: areaEn,
        governorateCode: governorateCode,
        areaCode: areaCode,
        price: parsePropertyDouble(priceController.text),
        size: parsePropertyDouble(sizeController.text),
        roomCount: parsePropertyInt(roomCountController.text),
        masterRoomCount: parsePropertyInt(masterRoomCountController.text),
        bathroomCount: parsePropertyInt(bathroomCountController.text),
        parkingCount: parsePropertyInt(parkingCountController.text),
        hasElevator: hasElevator,
        hasCentralAC: hasCentralAC,
        hasSplitAC: hasSplitAC,
        hasMaidRoom: hasMaidRoom,
        hasDriverRoom: hasDriverRoom,
        hasLaundryRoom: hasLaundryRoom,
        hasGarden: hasGarden,
        description: descriptionController.text,
        acceptLowerStartPrice: acceptLowerStartPrice,
        imageFile: pickedImage,
      );

      if (!mounted) return;

      await Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
          builder: (_) => AuctionPaymentPage(
            requestId: requestId,
            auctionFeeKwd: AuctionListingFees.defaultKwd,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        _toast('${loc.auctionRequestSubmitError}: $e');
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final textDirection = isArabic ? TextDirection.rtl : TextDirection.ltr;

    final user = FirebaseAuth.instance.currentUser;
    final canAccountSubmit = user != null && !user.isAnonymous;

    return Directionality(
      textDirection: textDirection,
      child: Scaffold(
        appBar: AppBar(
          title: Text(loc.auctionRequestPageTitle),
          centerTitle: true,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              if (!canAccountSubmit)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Card(
                    color: Colors.amber.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            loc.auctionRequestSignInRequired,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: _loading
                                ? null
                                : () {
                                    Navigator.of(context).push<void>(
                                      MaterialPageRoute<void>(
                                        builder: (_) => const LoginPage(),
                                      ),
                                    );
                                  },
                            child: Text(loc.auctionRequestSignInCta),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

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
                onChanged: _loading
                    ? null
                    : (v) => setState(() => selectedPropertyType = v),
              ),

              const SizedBox(height: 12),

              GestureDetector(
                onTap: _loading ? null : _openAreaSearchSheet,
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
                              : '$selectedArea — $selectedGovernorate',
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

              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: sizeController,
                      enabled: !_loading,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: loc.propertySize),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: priceController,
                      enabled: !_loading,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: loc.propertyPrice,
                      ),
                    ),
                  ),
                ],
              ),

              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _loading
                      ? null
                      : () {
                          setState(() {
                            _showAdvanced = !_showAdvanced;
                          });
                        },
                  child: Text(
                    _showAdvanced
                        ? 'إخفاء التفاصيل الإضافية'
                        : 'إضافة تفاصيل أكثر (اختياري)',
                  ),
                ),
              ),

              if (_showAdvanced) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: roomCountController,
                        enabled: !_loading,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: loc.roomCount),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: masterRoomCountController,
                        enabled: !_loading,
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
                        enabled: !_loading,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: loc.bathroomCount),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: parkingCountController,
                        enabled: !_loading,
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
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => hasElevator = v!),
                ),
                CheckboxListTile(
                  title: Text(loc.hasCentralAC),
                  value: hasCentralAC,
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => hasCentralAC = v!),
                ),
                CheckboxListTile(
                  title: Text(loc.hasSplitAC),
                  value: hasSplitAC,
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => hasSplitAC = v!),
                ),
                CheckboxListTile(
                  title: Text(loc.hasMaidRoom),
                  value: hasMaidRoom,
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => hasMaidRoom = v!),
                ),
                CheckboxListTile(
                  title: Text(loc.hasDriverRoom),
                  value: hasDriverRoom,
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => hasDriverRoom = v!),
                ),
                CheckboxListTile(
                  title: Text(loc.hasLaundryRoom),
                  value: hasLaundryRoom,
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => hasLaundryRoom = v!),
                ),
                CheckboxListTile(
                  title: Text(loc.hasGarden),
                  value: hasGarden,
                  onChanged: _loading
                      ? null
                      : (v) => setState(() => hasGarden = v!),
                ),
                const SizedBox(height: 12),
              ],

              DropdownButtonFormField<String>(
                value: _acceptLevel,
                decoration: const InputDecoration(
                  labelText: 'مرونة السعر',
                  border: OutlineInputBorder(),
                ),
                items: [_acceptAny, _acceptSlight, _acceptNo]
                    .map(
                      (e) => DropdownMenuItem<String>(
                        value: e,
                        child: Text(e),
                      ),
                    )
                    .toList(),
                onChanged: _loading
                    ? null
                    : (val) {
                        if (val == null) return;
                        setState(() => _acceptLevel = val);
                      },
              ),

              const SizedBox(height: 12),

              TextFormField(
                controller: descriptionController,
                enabled: !_loading,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: loc.description,
                  border: const OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 12),

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

              const SizedBox(height: 22),

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
                  onPressed: (_loading ||
                          !_acceptedTerms ||
                          !canAccountSubmit)
                      ? null
                      : _submitAuctionRequest,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black87,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _loading ? loc.publishing : loc.auctionRequestSubmitButton,
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
