// lib/pages/add_wanted_page.dart

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';

// المحافظات والمناطق (عربي / إنجليزي)
import 'package:aqarai_app/data/governorates_data_ar.dart';
import 'package:aqarai_app/data/governorates_data_en.dart';

// Firestore
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:aqarai_app/services/firestore.dart';

// 🔥 تسجيل الدخول (Email / Google / Apple)
import 'package:aqarai_app/auth/login_page.dart';

class AddWantedPage extends StatefulWidget {
  const AddWantedPage({super.key});

  @override
  State<AddWantedPage> createState() => _AddWantedPageState();
}

class _AddWantedPageState extends State<AddWantedPage> {
  static const bool requireLogin = true; // 🔥 مهم — لازم تسجيل دخول

  final _formKey = GlobalKey<FormState>();

  String? selectedGovernorate;
  String? selectedArea;
  String? selectedPropertyType;

  final TextEditingController ownerNameCtrl = TextEditingController();
  final TextEditingController ownerPhoneCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController minPriceCtrl = TextEditingController();
  final TextEditingController maxPriceCtrl = TextEditingController();

  bool _saving = false;

  @override
  void dispose() {
    ownerNameCtrl.dispose();
    ownerPhoneCtrl.dispose();
    descCtrl.dispose();
    minPriceCtrl.dispose();
    maxPriceCtrl.dispose();
    super.dispose();
  }

  // Normalize Arabic/Persian digits
  String _normalizeDigits(String input) {
    const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const persian = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

    var s = input.trim();
    for (int i = 0; i < 10; i++) {
      s = s.replaceAll(arabic[i], '$i').replaceAll(persian[i], '$i');
    }
    return s.replaceAll(RegExp(r'[^\d\.\-]'), '');
  }

  num? _tryParseNum(String txt) {
    final t = _normalizeDigits(txt);
    if (t.isEmpty) return null;
    return num.tryParse(t);
  }

  bool get _isArabic => Localizations.localeOf(context).languageCode == 'ar';

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final User? user = FirebaseAuth.instance.currentUser;

    final isAr = _isArabic;

    final governorates = isAr ? governoratesAndAreasAr : governoratesAndAreasEn;

    final governorateNames = governorates.keys.toList();
    final areaNames = selectedGovernorate != null
        ? governorates[selectedGovernorate] ?? <String>[]
        : <String>[];

    return Scaffold(
      appBar: AppBar(title: Text(loc.postWanted), centerTitle: true),

      body: (!requireLogin || user != null)
          ? Stack(
              children: [
                _WantedForm(
                  formKey: _formKey,
                  loc: loc,
                  governorateNames: governorateNames,
                  areaNames: areaNames,
                  selectedGovernorate: selectedGovernorate,
                  selectedArea: selectedArea,
                  selectedPropertyType: selectedPropertyType,
                  onGovChanged: (v) => setState(() {
                    selectedGovernorate = v;
                    selectedArea = null;
                  }),
                  onAreaChanged: (v) => setState(() => selectedArea = v),
                  onTypeChanged: (v) =>
                      setState(() => selectedPropertyType = v),
                  ownerNameCtrl: ownerNameCtrl,
                  ownerPhoneCtrl: ownerPhoneCtrl,
                  descCtrl: descCtrl,
                  minPriceCtrl: minPriceCtrl,
                  maxPriceCtrl: maxPriceCtrl,
                  onSubmit: _onSubmit,
                ),

                if (_saving)
                  Container(
                    color: Colors.black.withOpacity(0.05),
                    child: const Center(child: CircularProgressIndicator()),
                  ),
              ],
            )
          : _LoginGate(loc: loc),
    );
  }

  // -------------------------
  // SUBMIT
  // -------------------------
  Future<void> _onSubmit() async {
    final User? user = FirebaseAuth.instance.currentUser;

    if (requireLogin && user == null) {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    if (_saving) return;
    setState(() => _saving = true);

    try {
      final locale = Localizations.localeOf(context).languageCode;

      final minPrice = _tryParseNum(minPriceCtrl.text);
      final maxPrice = _tryParseNum(maxPriceCtrl.text);

      final data = {
        'governorate': selectedGovernorate,
        'area': selectedArea,
        'propertyType': selectedPropertyType,
        'type': selectedPropertyType,
        'ownerName': ownerNameCtrl.text.trim(),
        'ownerPhone': ownerPhoneCtrl.text.trim(),
        'description': descCtrl.text.trim(),
        'ownerId': user?.uid,
        'status': 'open',
        'approved': false,
        'createdAt': FieldValue.serverTimestamp(),
        'locale': locale,
      };

      if (minPrice != null) data['minPrice'] = minPrice;
      if (maxPrice != null) data['maxPrice'] = maxPrice;

      final ref = await firestore.collection('wanted_requests').add(data);

      if (!mounted) return;

      debugPrint('✅ Wanted request saved: ${ref.id}');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green,
          content: Text(
            _isArabic
                ? 'تم حفظ الطلب بنجاح. سيظهر في تبويب «مطلوب» عند الأدمن بعد الاتصال بالإنترنت، ثم اعتمده ليظهر للمستخدمين.'
                : 'Request saved. It will appear in Admin → Wanted tab (check internet). Approve it there to show for users.',
          ),
          duration: const Duration(seconds: 5),
        ),
      );

      setState(() {
        selectedGovernorate = null;
        selectedArea = null;
        selectedPropertyType = null;
        ownerNameCtrl.clear();
        ownerPhoneCtrl.clear();
        descCtrl.clear();
        minPriceCtrl.clear();
        maxPriceCtrl.clear();
      });

      Navigator.pop(context);
    } catch (e, st) {
      if (!mounted) return;
      debugPrint('❌ Wanted save error: $e\n$st');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text(
            _isArabic
                ? 'فشل الحفظ (تحقق من الإنترنت): $e'
                : 'Save failed (check internet): $e',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

// ===================================================================
// LOGIN GATE
// ===================================================================
class _LoginGate extends StatelessWidget {
  final AppLocalizations loc;
  const _LoginGate({required this.loc});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 75),
            const SizedBox(height: 16),
            Text(
              loc.errorMessagePlaceholder,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: 260,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                  );
                },
                icon: const Icon(Icons.login),
                label: Text(loc.login),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===================================================================
// PROPERTY TYPE LABEL MAPPER
// ===================================================================

String propertyTypeLabel(AppLocalizations loc, String key) {
  switch (key) {
    case 'apartment':
      return loc.propertyType_apartment;
    case 'house':
      return loc.propertyType_house;
    case 'building':
      return loc.propertyType_building;
    case 'land':
      return loc.propertyType_land;
    case 'industrialLand':
      return loc.propertyType_industrialLand;
    case 'shop':
      return loc.propertyType_shop;
    case 'office':
      return loc.propertyType_office;
    case 'chalet':
      return loc.propertyType_chalet;
    default:
      return key;
  }
}

// ===================================================================
// FORM UI
// ===================================================================
class _WantedForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final AppLocalizations loc;

  final List<String> governorateNames;
  final List<String> areaNames;

  final String? selectedGovernorate;
  final String? selectedArea;
  final String? selectedPropertyType;

  final ValueChanged<String?> onGovChanged;
  final ValueChanged<String?> onAreaChanged;
  final ValueChanged<String?> onTypeChanged;

  final TextEditingController ownerNameCtrl;
  final TextEditingController ownerPhoneCtrl;
  final TextEditingController descCtrl;
  final TextEditingController minPriceCtrl;
  final TextEditingController maxPriceCtrl;

  final VoidCallback onSubmit;

  const _WantedForm({
    required this.formKey,
    required this.loc,
    required this.governorateNames,
    required this.areaNames,
    required this.selectedGovernorate,
    required this.selectedArea,
    required this.selectedPropertyType,
    required this.onGovChanged,
    required this.onAreaChanged,
    required this.onTypeChanged,
    required this.ownerNameCtrl,
    required this.ownerPhoneCtrl,
    required this.descCtrl,
    required this.minPriceCtrl,
    required this.maxPriceCtrl,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final propertyTypes = <MapEntry<String, String>>[
      MapEntry('apartment', loc.propertyType_apartment),
      MapEntry('house', loc.propertyType_house),
      MapEntry('building', loc.propertyType_building),
      MapEntry('land', loc.propertyType_land),
      MapEntry('industrialLand', loc.propertyType_industrialLand),
      MapEntry('shop', loc.propertyType_shop),
      MapEntry('office', loc.propertyType_office),
      MapEntry('chalet', loc.propertyType_chalet),
    ];

    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Form(
      key: formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: selectedGovernorate,
            decoration: InputDecoration(
              labelText: isAr ? "المحافظة" : "Governorate",
            ),
            items: governorateNames
                .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                .toList(),
            onChanged: onGovChanged,
            validator: (v) => v == null
                ? (isAr ? "اختر المحافظة" : "Select governorate")
                : null,
          ),

          const SizedBox(height: 12),

          DropdownButtonFormField<String>(
            initialValue: selectedArea,
            decoration: InputDecoration(labelText: loc.selectArea),
            items: areaNames
                .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                .toList(),
            onChanged: (selectedGovernorate != null) ? onAreaChanged : null,
            validator: (v) =>
                v == null ? (isAr ? "اختر المنطقة" : "Select area") : null,
          ),

          const SizedBox(height: 12),

          DropdownButtonFormField<String>(
            initialValue: selectedPropertyType,
            decoration: InputDecoration(labelText: loc.propertyType),
            items: propertyTypes
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: onTypeChanged,
            validator: (v) =>
                v == null ? (isAr ? "اختر نوع العقار" : "Select type") : null,
          ),

          const SizedBox(height: 12),

          TextFormField(
            controller: ownerNameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: loc.valuation_ownerName),
            validator: (v) => v == null || v.trim().isEmpty
                ? (isAr ? "أدخل اسم المالك" : "Enter owner name")
                : null,
          ),

          const SizedBox(height: 12),

          TextFormField(
            controller: ownerPhoneCtrl,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: loc.valuation_phone),
            validator: (v) => v == null || v.trim().isEmpty
                ? (isAr ? "أدخل رقم التلفون" : "Enter phone number")
                : null,
          ),

          const SizedBox(height: 12),

          TextFormField(
            controller: descCtrl,
            maxLines: 4,
            decoration: InputDecoration(labelText: loc.propertyDescription),
            validator: (v) => v == null || v.trim().isEmpty
                ? (isAr ? "اكتب الوصف" : "Enter description")
                : null,
          ),

          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: minPriceCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الحد الأدنى للسعر' : 'Min price',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: maxPriceCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: isAr ? 'الحد الأقصى للسعر' : 'Max price',
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onSubmit,
              icon: const Icon(Icons.send),
              label: Text(loc.postWanted),
            ),
          ),
        ],
      ),
    );
  }
}
