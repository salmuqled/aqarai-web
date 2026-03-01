// lib/pages/valuation_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

// 🟦 المحافظات والمناطق (عربي / إنجليزي)
import 'package:aqarai_app/data/governorates_data_ar.dart';
import 'package:aqarai_app/data/governorates_data_en.dart';

class ValuationPage extends StatefulWidget {
  const ValuationPage({super.key});

  @override
  State<ValuationPage> createState() => _ValuationPageState();
}

class _ValuationPageState extends State<ValuationPage> {
  final _formKey = GlobalKey<FormState>();
  final FirebaseFirestore firestore = FirebaseFirestore.instance;

  // Controllers
  final _ownerNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _propertyAreaCtrl = TextEditingController();
  final _buildYearCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  String? _selectedGovernorate;
  String? _selectedArea;
  String? _selectedType;
  String? _selectedCondition;
  String? _selectedPurpose;

  /// محافظة → قائمة المناطق
  late Map<String, List<String>> _govMapFlat;

  List<String> _types = [];
  List<String> _conditions = [];
  List<String> _purposes = [];

  bool _saving = false;

  bool get _isArabic => Localizations.localeOf(context).languageCode == 'ar';
  String _t(String ar, String en) => _isArabic ? ar : en;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    /// 👇 النوع الصحيح للخرائط
    final Map<String, List<String>> source = _isArabic
        ? governoratesAndAreasAr
        : governoratesAndAreasEn;

    /// 👇 Flatten: محافظة → قائمة المناطق
    _govMapFlat = {};
    source.forEach((String gov, List<String> areasList) {
      _govMapFlat[gov] = areasList;
    });

    // Property Types
    _types = [
      _t('شقة', 'Apartment'),
      _t('فيلا', 'Villa'),
      _t('أرض', 'Land'),
      _t('تجاري', 'Commercial'),
    ];

    // Property Condition
    _conditions = [
      _t('جديد', 'New'),
      _t('جيد جدًا', 'Very good'),
      _t('جيد', 'Good'),
      _t('بحاجة إلى ترميم', 'Needs renovation'),
    ];

    // Purpose
    _purposes = [
      _t('للبيع', 'For sale'),
      _t('للإيجار', 'For rent'),
      _t('للرهن', 'Mortgage'),
      _t('تقييم السوق', 'Market valuation'),
    ];
  }

  @override
  void dispose() {
    _ownerNameCtrl.dispose();
    _phoneCtrl.dispose();
    _propertyAreaCtrl.dispose();
    _buildYearCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  // =====================================================
  // Normalizers
  // =====================================================

  String _normalizeDigits(String input) {
    const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const latin = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    for (int i = 0; i < arabic.length; i++) {
      input = input.replaceAll(arabic[i], latin[i]);
    }
    return input;
  }

  double? _parseArea(String raw) {
    var t = _normalizeDigits(raw.trim());
    t = t.replaceAll('،', '.').replaceAll(',', '.');
    return double.tryParse(t);
  }

  int? _parseYear(String raw) {
    return int.tryParse(_normalizeDigits(raw.trim()));
  }

  bool _isValidKuwaitMobile(String raw) {
    final n = _normalizeDigits(raw.replaceAll(RegExp(r'\D'), ''));
    return n.length == 8 &&
        (n.startsWith('5') || n.startsWith('6') || n.startsWith('9'));
  }

  String get _requiredMsg => _t('هذا الحقل مطلوب', 'This field is required');

  // =====================================================
  // Submit to Firestore
  // =====================================================

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_saving) return;

    setState(() => _saving = true);

    final area = _parseArea(_propertyAreaCtrl.text);
    final year = _parseYear(_buildYearCtrl.text);
    final phone = _normalizeDigits(_phoneCtrl.text.trim());

    final user = FirebaseAuth.instance.currentUser;
    try {
      final data = {
        'ownerName': _ownerNameCtrl.text.trim(),
        'phone': '+965$phone',
        'governorate': _selectedGovernorate,
        'area': _selectedArea,
        'propertyType': _selectedType,
        'propertyArea': area,
        'buildYear': year,
        'condition': _selectedCondition,
        'purpose': _selectedPurpose,
        'notes': _notesCtrl.text.trim(),
        'status': 'pending',
        'approved': false,
        'lang': Localizations.localeOf(context).languageCode,
        'createdAt': FieldValue.serverTimestamp(),
      };
      if (user != null) data['ownerId'] = user.uid;
      await firestore.collection('valuations').add(data);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _t(
              'تم إرسال طلب التقييم بنجاح',
              'Valuation request submitted successfully',
            ),
          ),
        ),
      );

      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _t(
                'حدث خطأ أثناء إرسال الطلب',
                'An error occurred while submitting the request',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // =====================================================
  // UI
  // =====================================================

  @override
  Widget build(BuildContext context) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final governorates = _govMapFlat.keys.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_t('التقييم العقاري', 'Real Estate Valuation')),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: isRtl
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Text(
                      _t(
                        'يرجى تعبئة البيانات التالية لإتمام طلب التقييم العقاري',
                        'Please fill in the following details to submit a valuation request',
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),

                    // Name
                    TextFormField(
                      controller: _ownerNameCtrl,
                      decoration: InputDecoration(
                        labelText: _t('اسم المالك', 'Owner name'),
                        border: const OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? _requiredMsg : null,
                    ),
                    const SizedBox(height: 12),

                    // Phone
                    TextFormField(
                      controller: _phoneCtrl,
                      decoration: InputDecoration(
                        prefixText: '+965 ',
                        labelText: _t('رقم الهاتف', 'Phone number'),
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩]')),
                        LengthLimitingTextInputFormatter(8),
                      ],
                      validator: (v) {
                        if (v == null || v.isEmpty) return _requiredMsg;
                        if (!_isValidKuwaitMobile(v)) return _requiredMsg;
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    // Governorate
                    DropdownButtonFormField<String>(
                      value: _selectedGovernorate,
                      decoration: InputDecoration(
                        labelText: _t('المحافظة', 'Governorate'),
                        border: const OutlineInputBorder(),
                      ),
                      items: governorates
                          .map(
                            (g) => DropdownMenuItem(value: g, child: Text(g)),
                          )
                          .toList(),
                      onChanged: (v) {
                        setState(() {
                          _selectedGovernorate = v;
                          _selectedArea = null;
                        });
                      },
                      validator: (v) => (v == null) ? _requiredMsg : null,
                    ),
                    const SizedBox(height: 12),

                    // Area
                    DropdownButtonFormField<String>(
                      value: _selectedArea,
                      decoration: InputDecoration(
                        labelText: _t('المنطقة', 'Area'),
                        border: const OutlineInputBorder(),
                      ),
                      items: _selectedGovernorate == null
                          ? const []
                          : _govMapFlat[_selectedGovernorate]!
                                .map(
                                  (a) => DropdownMenuItem(
                                    value: a,
                                    child: Text(a),
                                  ),
                                )
                                .toList(),
                      onChanged: (v) => setState(() => _selectedArea = v),
                      validator: (v) => (v == null) ? _requiredMsg : null,
                    ),
                    const SizedBox(height: 12),

                    // Property Type
                    DropdownButtonFormField<String>(
                      value: _selectedType,
                      decoration: InputDecoration(
                        labelText: _t('نوع العقار', 'Property type'),
                        border: const OutlineInputBorder(),
                      ),
                      items: _types
                          .map(
                            (t) => DropdownMenuItem(value: t, child: Text(t)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _selectedType = v),
                      validator: (v) => (v == null) ? _requiredMsg : null,
                    ),
                    const SizedBox(height: 12),

                    // Area Size
                    TextFormField(
                      controller: _propertyAreaCtrl,
                      decoration: InputDecoration(
                        labelText: _t(
                          'مساحة العقار (م²)',
                          'Property area (m²)',
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9٠-٩\.,،]'),
                        ),
                      ],
                      validator: (v) {
                        if (v == null || v.isEmpty) return _requiredMsg;
                        final a = _parseArea(v);
                        if (a == null || a <= 0) return _requiredMsg;
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    // Build Year
                    TextFormField(
                      controller: _buildYearCtrl,
                      decoration: InputDecoration(
                        labelText: _t('سنة البناء', 'Build year'),
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9٠-٩]')),
                        LengthLimitingTextInputFormatter(4),
                      ],
                      validator: (v) {
                        if (v == null || v.isEmpty) return _requiredMsg;
                        final y = _parseYear(v);
                        final now = DateTime.now().year;
                        if (y == null || y < 1900 || y > now) {
                          return _requiredMsg;
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    // Condition
                    DropdownButtonFormField<String>(
                      value: _selectedCondition,
                      decoration: InputDecoration(
                        labelText: _t('حالة العقار', 'Property condition'),
                        border: const OutlineInputBorder(),
                      ),
                      items: _conditions
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _selectedCondition = v),
                      validator: (v) => (v == null) ? _requiredMsg : null,
                    ),
                    const SizedBox(height: 12),

                    // Purpose
                    DropdownButtonFormField<String>(
                      value: _selectedPurpose,
                      decoration: InputDecoration(
                        labelText: _t('غرض التقييم', 'Valuation purpose'),
                        border: const OutlineInputBorder(),
                      ),
                      items: _purposes
                          .map(
                            (p) => DropdownMenuItem(value: p, child: Text(p)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _selectedPurpose = v),
                      validator: (v) => (v == null) ? _requiredMsg : null,
                    ),
                    const SizedBox(height: 12),

                    // Notes
                    TextFormField(
                      controller: _notesCtrl,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: _t('ملاحظات إضافية', 'Additional notes'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 22),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: _saving
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                _t(
                                  'إرسال طلب التقييم',
                                  'Submit valuation request',
                                ),
                                style: const TextStyle(fontSize: 18),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (_saving) ...[
              Container(color: Colors.black.withOpacity(0.05)),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }
}
