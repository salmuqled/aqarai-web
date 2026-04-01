import 'package:flutter/material.dart';

import 'package:aqarai_app/data/governorates_data_ar.dart';
import 'package:aqarai_app/data/governorates_data_en.dart';

/// Bottom sheet to pick governorate + area (same UX as [AddPropertyPage]).
void showPropertyAreaSearchSheet(
  BuildContext context, {
  required void Function(String governorate, String area) onAreaSelected,
}) {
  final isArabic = Localizations.localeOf(context).languageCode == 'ar';
  final data = isArabic ? governoratesAndAreasAr : governoratesAndAreasEn;

  final List<Map<String, String>> allAreas = [];
  data.forEach((gov, areas) {
    for (final area in areas) {
      allAreas.add({'governorate': gov, 'area': area});
    }
  });

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (modalContext) {
      String query = '';

      return StatefulBuilder(
        builder: (context, setModalState) {
          final filtered = allAreas.where((item) {
            final a = item['area']!.toLowerCase();
            final g = item['governorate']!.toLowerCase();
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
                      hintText: isArabic ? 'ابحث عن المنطقة' : 'Search area',
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
                        title: Text(item['area']!),
                        subtitle: Text(item['governorate']!),
                        onTap: () {
                          Navigator.pop(modalContext);
                          onAreaSelected(
                            item['governorate']!,
                            item['area']!,
                          );
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
