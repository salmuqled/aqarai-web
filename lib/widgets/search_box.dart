// lib/widgets/search_box.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:aqarai_app/widgets/property_list.dart';
import 'package:aqarai_app/widgets/property_area_search_sheet.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

// Arabic governorate labels need Latin slug for [governorateCode] ([_code] is ASCII-only).
import 'package:aqarai_app/data/ar_to_en_mapping.dart' show governorateArToEn;
import 'package:aqarai_app/data/kuwait_areas.dart';

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
  /// Canonical Firestore `serviceType`: `sale` | `rent` | `exchange` (never localized).
  String selectedService = 'sale';

  String? selectedGovernorate;
  String? selectedArea;
  String? selectedProperty;

  /// For [PropertyList] when searching [serviceType] rent (daily vs monthly).
  String selectedRentalType = 'daily';

  String? _lastLocaleCode;
  bool _appliedInitialSearchService = false;

  late List<String> localizedPropertyTypes;

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
    }

    _lastLocaleCode = localeCode;

    if (!_appliedInitialSearchService) {
      final init = widget.initialSearchType?.trim().toLowerCase();
      if (init == 'rent' || init == 'sale' || init == 'exchange') {
        selectedService = init!;
      }
      _appliedInitialSearchService = true;
    }

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
  }

  void _openLocationPicker() {
    showPropertyAreaSearchSheet(
      context,
      chaletAreasOnly: widget.isChaletMode,
      onAreaSelected: (governorate, area) {
        setState(() {
          selectedGovernorate = governorate;
          selectedArea = area;
        });
      },
    );
  }

  String _locationFieldLabel(AppLocalizations loc) {
    if (selectedArea != null && selectedGovernorate != null) {
      return '$selectedArea — $selectedGovernorate';
    }
    return loc.selectAreaToSearch;
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
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: _openLocationPicker,
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
                      _locationFieldLabel(loc),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: (selectedArea != null &&
                                selectedGovernorate != null)
                            ? Colors.black
                            : Colors.black54,
                      ),
                    ),
                  ),
                  const Icon(Icons.search, color: Colors.black),
                ],
              ),
            ),
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
                isSelected: selectedService == 'sale',
                onPressed: () => setState(() => selectedService = 'sale'),
              ),
              _buildServiceButton(
                label: loc.forRent,
                isSelected: selectedService == 'rent',
                onPressed: () => setState(() => selectedService = 'rent'),
              ),
              _buildServiceButton(
                label: loc.forExchange,
                isSelected: selectedService == 'exchange',
                onPressed: () => setState(() => selectedService = 'exchange'),
              ),
            ],
          ),
          if (selectedService == 'rent') ...[
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: [
                ButtonSegment<String>(
                  value: 'daily',
                  label: Text(isAr ? 'يومي' : 'Daily'),
                ),
                ButtonSegment<String>(
                  value: 'monthly',
                  label: Text(isAr ? 'شهري / سنوي' : 'Monthly / Yearly'),
                ),
              ],
              selected: {selectedRentalType},
              onSelectionChanged: (Set<String> next) {
                if (next.isEmpty) return;
                setState(() => selectedRentalType = next.first);
              },
              multiSelectionEnabled: false,
              emptySelectionAllowed: false,
              showSelectedIcon: false,
            ),
          ],
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
              final canSearch =
                  selectedGovernorate != null && selectedArea != null;

              if (!canSearch) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(loc.selectAreaToSearch)),
                );
                return;
              }

              final govLabel = selectedGovernorate!;
              final areaLabel = selectedArea!;

              final String governorateCode = widget.isChaletMode
                  ? _code('chalet')
                  : _code(governorateArToEn[govLabel] ?? govLabel);

              final String selectedAreaCode = getUnifiedAreaCode(
                areaLabel,
                fallbackSlugSource: areaLabel,
              );

              if (kDebugMode) {
                debugPrint('AREA INPUT → $areaLabel');
                debugPrint('FINAL CODE → $selectedAreaCode');
              }

              final propertyCode = selectedProperty != null
                  ? _mapPropertyToCode(selectedProperty!, loc)
                  : null;

              if (kDebugMode) {
                debugPrint(
                  '[SearchBox→PropertyList] selectedService=$selectedService',
                );
                debugPrint(
                  '[SearchBox→PropertyList] selectedProperty (typeFilter label)=$selectedProperty '
                  '| typeFilter code=$propertyCode',
                );
                debugPrint(
                  '[SearchBox→PropertyList] selectedGovernorate (raw)=$selectedGovernorate',
                );
                debugPrint(
                  '[SearchBox→PropertyList] selectedArea (raw)=$selectedArea',
                );
                debugPrint(
                  '[SearchBox→PropertyList] computed governorateCode=$governorateCode',
                );
                debugPrint(
                  '[SearchBox→PropertyList] computed areaCode=$selectedAreaCode',
                );
              }

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PropertyList(
                    governorateLabel: widget.isChaletMode
                        ? loc.chalets
                        : selectedGovernorate ?? '',
                    areaLabel: selectedArea ?? '',
                    governorateCode: governorateCode,
                    areaCode: selectedAreaCode,
                    typeFilter: propertyCode,
                    serviceType: selectedService,
                    rentalType: selectedService == 'rent'
                        ? selectedRentalType
                        : null,
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
