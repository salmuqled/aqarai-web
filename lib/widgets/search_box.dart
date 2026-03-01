// lib/widgets/search_box.dart

import 'package:flutter/material.dart';
import 'package:aqarai_app/widgets/property_list.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

// الخرائط الرسمية (عربي / إنجليزي)
import 'package:aqarai_app/data/governorates_data_ar.dart';
import 'package:aqarai_app/data/governorates_data_en.dart';

// 🔥 AR → EN mapping
import 'package:aqarai_app/data/ar_to_en_mapping.dart';

class AqarSearchBox extends StatefulWidget {
  final String? initialSearchType;
  final bool isChaletMode;

  const AqarSearchBox({
    super.key,
    this.initialSearchType,
    this.isChaletMode = false,
  });

  @override
  State<AqarSearchBox> createState() => _AqarSearchBoxState();
}

class _AqarSearchBoxState extends State<AqarSearchBox> {
  String selectedType = '';
  String? selectedGovernorate;
  String? selectedArea;
  String? selectedProperty;

  String? _lastLocaleCode;

  late List<String> localizedPropertyTypes;

  late List<String> chaletAreasAr;
  late List<String> chaletAreasEn;

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
  void didChangeDependencies() {
    super.didChangeDependencies();

    final loc = AppLocalizations.of(context)!;
    final localeCode = Localizations.localeOf(context).languageCode;

    if (_lastLocaleCode != null && _lastLocaleCode != localeCode) {
      selectedGovernorate = null;
      selectedArea = null;
      selectedProperty = null;
      selectedType = widget.initialSearchType ?? loc.forSale;
    }

    _lastLocaleCode = localeCode;

    selectedType = widget.initialSearchType ?? loc.forSale;

    localizedPropertyTypes = [
      loc.propertyType_apartment,
      loc.propertyType_house,
      loc.propertyType_building,
      loc.propertyType_land,
      loc.propertyType_industrialLand,
      loc.propertyType_shop,
      loc.propertyType_office,
      loc.propertyType_chalet,
    ];

    chaletAreasAr = const [
      'الخيران',
      'بنيدر',
      'الزور',
      'النويصيب',
      'الجليعة',
      'الضباعية',
    ];

    chaletAreasEn = const [
      'Khiran',
      'Bneider',
      'Zour',
      'Nuwaiseeb',
      'Julaia',
      'Dhubaiya',
    ];
  }

  void _showGovernoratesSheet() {
    final localeCode = Localizations.localeOf(context).languageCode;

    final List<String> items = widget.isChaletMode
        ? (localeCode == 'ar' ? chaletAreasAr : chaletAreasEn)
        : (localeCode == 'ar'
              ? governoratesAndAreasAr.keys.toList()
              : governoratesAndAreasEn.keys.toList());

    showModalBottomSheet(
      context: context,
      builder: (_) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: items.map((item) {
              return ListTile(
                title: Text(item),
                onTap: () {
                  setState(() {
                    if (widget.isChaletMode) {
                      selectedGovernorate = 'chalet';
                      selectedArea = item;
                    } else {
                      selectedGovernorate = item;
                      selectedArea = null;
                    }
                  });
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  String? _mapPropertyToCode(String label, AppLocalizations loc) {
    if (label == loc.propertyType_apartment) return 'apartment';
    if (label == loc.propertyType_house) return 'house';
    if (label == loc.propertyType_building) return 'building';
    if (label == loc.propertyType_land) return 'land';
    if (label == loc.propertyType_industrialLand) return 'industrialLand';
    if (label == loc.propertyType_shop) return 'shop';
    if (label == loc.propertyType_office) return 'office';
    if (label == loc.propertyType_chalet) return 'chalet';
    return null;
  }

  Widget _buildServiceButton({
    required String label,
    required bool isSelected,
    required VoidCallback onPressed,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            backgroundColor: isSelected ? Colors.white : Colors.transparent,
            side: BorderSide(color: Colors.white.withOpacity(0.75)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: onPressed,
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.black : Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final localeCode = Localizations.localeOf(context).languageCode;

    List<String> areaList = [];

    if (widget.isChaletMode) {
      areaList = localeCode == 'ar' ? chaletAreasAr : chaletAreasEn;
    } else if (selectedGovernorate != null) {
      areaList = localeCode == 'ar'
          ? governoratesAndAreasAr[selectedGovernorate] ?? []
          : governoratesAndAreasEn[selectedGovernorate] ?? [];
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: _showGovernoratesSheet,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 18),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.85),
                border: Border.all(color: Colors.white.withOpacity(0.70)),
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      selectedGovernorate ?? loc.enterAreaToSearch,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.black),
                    ),
                  ),
                  const Icon(Icons.search, color: Colors.black),
                ],
              ),
            ),
          ),
          const SizedBox(height: 15),
          if (!widget.isChaletMode && selectedGovernorate != null)
            DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: InputDecoration(
                labelText: loc.selectArea,
                labelStyle: const TextStyle(color: Colors.white),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.75)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: const BorderSide(color: Colors.white, width: 2),
                ),
              ),
              dropdownColor: const Color(0xFF0B0F1A),
              iconEnabledColor: Colors.white,
              style: const TextStyle(color: Colors.white),
              items: areaList
                  .map(
                    (area) => DropdownMenuItem(value: area, child: Text(area)),
                  )
                  .toList(),
              value: selectedArea,
              onChanged: (value) => setState(() => selectedArea = value),
            ),
          const SizedBox(height: 15),
          DropdownButtonFormField<String>(
            isExpanded: true,
            decoration: InputDecoration(
              labelText: loc.propertyType,
              labelStyle: const TextStyle(color: Colors.white),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.75)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(30),
                borderSide: const BorderSide(color: Colors.white, width: 2),
              ),
            ),
            dropdownColor: const Color(0xFF0B0F1A),
            iconEnabledColor: Colors.white,
            style: const TextStyle(color: Colors.white),
            items: localizedPropertyTypes
                .map((type) => DropdownMenuItem(value: type, child: Text(type)))
                .toList(),
            value: selectedProperty,
            onChanged: (value) => setState(() => selectedProperty = value),
          ),
          const SizedBox(height: 15),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildServiceButton(
                label: loc.forSale,
                isSelected: selectedType == loc.forSale,
                onPressed: () => setState(() => selectedType = loc.forSale),
              ),
              _buildServiceButton(
                label: loc.forRent,
                isSelected: selectedType == loc.forRent,
                onPressed: () => setState(() => selectedType = loc.forRent),
              ),
              _buildServiceButton(
                label: loc.forExchange,
                isSelected: selectedType == loc.forExchange,
                onPressed: () => setState(() => selectedType = loc.forExchange),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            onPressed: () {
              final bool canSearch = widget.isChaletMode
                  ? selectedArea != null
                  : (selectedGovernorate != null && selectedArea != null);

              if (!canSearch) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(loc.selectGovernorateAndArea)),
                );
                return;
              }

              String govAr = selectedGovernorate ?? '';
              String areaAr = selectedArea ?? '';

              String govEn = governorateArToEn[govAr] ?? govAr;
              String areaEn = areaArToEn[areaAr] ?? areaAr;

              if (widget.isChaletMode) {
                govAr = 'chalet';
                govEn = 'chalet';
              }

              final governorateCode = _code(govEn.isNotEmpty ? govEn : govAr);
              final areaCode = _code(areaEn.isNotEmpty ? areaEn : areaAr);

              final propertyCode = selectedProperty != null
                  ? _mapPropertyToCode(selectedProperty!, loc)
                  : null;

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PropertyList(
                    governorateLabel: widget.isChaletMode
                        ? (localeCode == 'ar' ? "الشاليهات" : "Chalets")
                        : selectedGovernorate ?? '',
                    areaLabel: selectedArea ?? '',
                    governorateCode: governorateCode,
                    areaCode: areaCode,
                    typeFilter: propertyCode,
                    serviceType: selectedType == loc.forRent
                        ? "rent"
                        : selectedType == loc.forExchange
                        ? "exchange"
                        : "sale",
                  ),
                ),
              );
            },
            child: Text(
              loc.search,
              style: const TextStyle(color: Colors.black, fontSize: 18),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
