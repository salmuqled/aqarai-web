import 'package:flutter/material.dart';
import 'package:aqarai_app/data/kuwait_areas.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/utils/property_form_parsing.dart';
import 'package:aqarai_app/widgets/property_list.dart';

// ✔ قائمة الشاليهات النهائية
const List<String> chaletAreasAr = [
  'الخيران',
  'بنيدر',
  'الزور',
  'النويصيب',
  'الجليعة',
  'الضباعية',
];

const List<String> chaletAreasEn = [
  'Khiran',
  'Bneider',
  'Zour',
  'Nuwaiseeb',
  'Julaia',
  'Dhubaiya',
];

// ✔ أنواع العقار داخل قسم الشاليهات (Labels)
const List<String> chaletPropertyTypesAr = [
  'شاليه',
  'شقة',
  'أرض',
  'محل',
  'مكتب',
];

const List<String> chaletPropertyTypesEn = [
  'Chalet',
  'Apartment',
  'Land',
  'Shop',
  'Office',
];

// ✔ الأكواد الفعلية المخزّنة في Firestore
const List<String> chaletPropertyTypeCodes = [
  'chalet',
  'apartment',
  'land',
  'shop',
  'office',
];

class SearchBoxChalet extends StatefulWidget {
  const SearchBoxChalet({super.key});

  @override
  State<SearchBoxChalet> createState() => _SearchBoxChaletState();
}

class _SearchBoxChaletState extends State<SearchBoxChalet> {
  String? selectedArea;
  String? selectedPropertyType;
  String selectedServiceType = "sale";

  void _search() {
    if (selectedArea == null || selectedPropertyType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.selectArea,
            textAlign: TextAlign.center,
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final localeCode = Localizations.localeOf(context).languageCode;

    final String areaLabel = selectedArea!;
    final String typeLabel = selectedPropertyType!;

    final List<String> typesList = localeCode == 'ar'
        ? chaletPropertyTypesAr
        : chaletPropertyTypesEn;

    final int typeIndex = typesList.indexOf(typeLabel);

    final String typeCode =
        (typeIndex >= 0 && typeIndex < chaletPropertyTypeCodes.length)
        ? chaletPropertyTypeCodes[typeIndex]
        : 'chalet';

    // Match Firestore [areaCode]: resolve from kuwait list, else slug from English label.
    final String enForSlug = () {
      final i = chaletAreasAr.indexOf(areaLabel);
      if (i >= 0 && i < chaletAreasEn.length) return chaletAreasEn[i];
      final j = chaletAreasEn.indexOf(areaLabel);
      if (j >= 0) return chaletAreasEn[j];
      return areaLabel;
    }();
    final String selectedAreaCode = resolveAreaCodeFromText(areaLabel) ??
        propertyLocationCode(enForSlug);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PropertyList(
          governorateLabel: localeCode == 'ar' ? 'الشاليهات' : 'Chalets',
          areaLabel: areaLabel,
          governorateCode: 'chalet',
          areaCode: selectedAreaCode,
          typeFilter: typeCode,
          serviceType: selectedServiceType,
        ),
      ),
    );
  }

  Widget _serviceButton(String value, String label) {
    final bool active = selectedServiceType == value;

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            backgroundColor: active ? Colors.white : Colors.transparent,
            side: BorderSide(color: Colors.white.withOpacity(0.75)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          onPressed: () => setState(() => selectedServiceType = value),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.black : Colors.white,
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

    final List<String> areas = localeCode == "ar"
        ? chaletAreasAr
        : chaletAreasEn;

    final List<String> types = localeCode == "ar"
        ? chaletPropertyTypesAr
        : chaletPropertyTypesEn;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
            items: areas
                .map((area) => DropdownMenuItem(value: area, child: Text(area)))
                .toList(),
            value: selectedArea,
            onChanged: (value) => setState(() => selectedArea = value),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            isExpanded: true,
            decoration: InputDecoration(
              labelText: localeCode == 'ar' ? 'نوع العقار' : 'Property Type',
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
            items: types
                .map((type) => DropdownMenuItem(value: type, child: Text(type)))
                .toList(),
            value: selectedPropertyType,
            onChanged: (value) => setState(() => selectedPropertyType = value),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _serviceButton("sale", loc.forSale),
              _serviceButton("rent", loc.forRent),
              _serviceButton("exchange", loc.forExchange),
            ],
          ),
          const SizedBox(height: 25),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            onPressed: _search,
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
