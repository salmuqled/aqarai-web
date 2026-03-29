// lib/services/conversational_search_service.dart
// Phase 1: تحليل رسالة المستخدم (عربي/إنجليزي) واستخراج فلاتر + أسئلة توضيحية + بناء استعلام Firestore

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:aqarai_app/data/ar_to_en_mapping.dart';
import 'package:aqarai_app/data/governorates_data_ar.dart';

/// نتيجة تحليل رسالة البحث المحادثي
class ConversationalSearchResult {
  final ParsedFilters filters;
  final List<String> clarificationQuestions;
  final bool canRunQuery;

  const ConversationalSearchResult({
    required this.filters,
    required this.clarificationQuestions,
    required this.canRunQuery,
  });
}

/// فلاتر مستخرجة من النص أو من خريطة الـ Agent
class ParsedFilters {
  final String? areaCode;
  final String? governorateCode;
  final String? serviceType; // sale | rent
  final String? propertyType; // house, apartment, villa, chalet, ...
  final double? maxPrice;
  final int? bedrooms; // roomCount في Firestore

  const ParsedFilters({
    this.areaCode,
    this.governorateCode,
    this.serviceType,
    this.propertyType,
    this.maxPrice,
    this.bedrooms,
  });

  bool get hasArea => areaCode != null && areaCode!.isNotEmpty;
}

/// خدمة البحث المحادثي — تحليل محلي بدون Cloud Function
class ConversationalSearchService {
  static String _code(String s) {
    var v = s.trim().toLowerCase();
    v = v.replaceAll(RegExp(r'\s+'), '_');
    v = v.replaceAll('-', '_');
    v = v.replaceAll(RegExp(r'[^a-z0-9_]+'), '');
    v = v.replaceAll(RegExp(r'_+'), '_');
    v = v.replaceAll(RegExp(r'^_+|_+$'), '');
    return v;
  }

  static final Map<String, String> _areaNameToAreaCode = _buildAreaNameToCode();
  static final Map<String, String> _areaToGovernorateCode = _buildAreaToGovernorateCode();

  static Map<String, String> _buildAreaNameToCode() {
    final out = <String, String>{};
    for (final e in areaArToEn.entries) {
      final ar = e.key.trim().toLowerCase();
      final en = e.value.trim();
      final code = _code(en);
      if (code.isNotEmpty) {
        out[ar] = code;
        out[en.toLowerCase()] = code;
      }
    }
    return out;
  }

  /// areaCode أو اسم المنطقة (عربي/إنجليزي) -> governorateCode
  static Map<String, String> _buildAreaToGovernorateCode() {
    final out = <String, String>{};
    for (final e in governoratesAndAreasAr.entries) {
      final govAr = e.key;
      final govEn = governorateArToEn[govAr] ?? '';
      final govCode = _code(govEn);
      if (govCode.isEmpty) continue;
      for (final areaAr in e.value) {
        final areaEn = areaArToEn[areaAr] ?? areaAr;
        final areaCode = _code(areaEn);
        final areaArLower = areaAr.trim().toLowerCase();
        final areaEnLower = areaEn.trim().toLowerCase();
        if (areaCode.isNotEmpty) {
          out[areaCode] = govCode;
          out[areaArLower] = govCode;
          out[areaEnLower] = govCode;
        }
      }
    }
    return out;
  }

  // كلمات مفتاحية لنوع الخدمة
  static const List<String> _saleKeywordsAr = ['بيع', 'للبيع', 'شراء', 'ابي اشتري', 'أريد شراء'];
  static const List<String> _saleKeywordsEn = ['sale', 'buy', 'for sale', 'purchase'];
  static const List<String> _rentKeywordsAr = ['ايجار', 'إيجار', 'للإيجار', 'استأجر', 'ابي استأجر'];
  static const List<String> _rentKeywordsEn = ['rent', 'rental', 'lease', 'for rent'];

  // نوع العقار: قيمة Firestore <- كلمات عربي/إنجليزي
  static const Map<String, List<String>> _propertyTypeKeywords = {
    'house': ['house', 'بيت', 'منزل', 'دار'],
    'apartment': ['apartment', 'شقة', 'شقق', 'اپارتمان'],
    'villa': ['villa', 'فيلا', 'فلل'],
    'chalet': ['chalet', 'شاليه', 'شاليهات'],
    'shop': ['shop', 'محل', 'محلات', 'متجر'],
    'office': ['office', 'مكتب', 'مكاتب'],
    'land': ['land', 'أرض', 'اراضي'],
    'warehouse': ['warehouse', 'مخزن'],
    'farm': ['farm', 'مزرعة'],
    'room': ['room', 'غرفة', 'غرف'],
  };

  /// يحلل الرسالة ويرجع الفلاتر + أسئلة توضيحية
  ConversationalSearchResult parse(String userMessage) {
    final text = userMessage.trim();
    final lower = text.toLowerCase();
    String? areaCode;
    String? governorateCode;
    String? serviceType;
    String? propertyType;
    double? maxPrice;
    final clarificationQuestions = <String>[];

    // استخراج المنطقة (مطلوب للاستعلام)
    for (final e in _areaNameToAreaCode.entries) {
      if (lower.contains(e.key)) {
        areaCode = e.value;
        governorateCode = _areaToGovernorateCode[e.key] ?? _areaToGovernorateCode[e.value];
        break;
      }
    }
    if (areaCode == null || areaCode.isEmpty) {
      clarificationQuestions.add('في أي منطقة تبحث؟ (مثال: القادسية، النزهة، السالمية)');
    }

    // نوع الخدمة
    for (final k in _rentKeywordsAr) {
      if (lower.contains(k)) {
        serviceType = 'rent';
        break;
      }
    }
    if (serviceType == null) {
      for (final k in _rentKeywordsEn) {
        if (lower.contains(k)) {
          serviceType = 'rent';
          break;
        }
      }
    }
    if (serviceType == null) {
      for (final k in _saleKeywordsAr) {
        if (lower.contains(k)) {
          serviceType = 'sale';
          break;
        }
      }
    }
    if (serviceType == null) {
      for (final k in _saleKeywordsEn) {
        if (lower.contains(k)) {
          serviceType = 'sale';
          break;
        }
      }
    }

    // نوع العقار
    for (final e in _propertyTypeKeywords.entries) {
      for (final kw in e.value) {
        if (lower.contains(kw)) {
          propertyType = e.key;
          break;
        }
      }
      if (propertyType != null) break;
    }

    // أقصى سعر — أرقام مع د.ك، ك، ألف، مليون
    final priceReg = RegExp(r'(\d+(?:\.\d+)?)\s*(?:الف|ألف|الفا|ك|د\.ك|kd|kwd|thousand|مليون|million)?', caseSensitive: false);
    final priceMatch = priceReg.firstMatch(text);
    if (priceMatch != null) {
      var num = double.tryParse(priceMatch.group(1) ?? '') ?? 0;
      final rest = text.substring(priceMatch.end).trim().toLowerCase();
      if (rest.startsWith('مليون') || rest.startsWith('million') || text.contains('مليون') || text.contains('million')) {
        num *= 1000000;
      } else if (rest.startsWith('الف') || rest.startsWith('ألف') || rest.startsWith('ك') || rest.contains('الف') || rest.contains('thousand') || rest.contains('k ')) {
        num *= 1000;
      }
      if (num > 0) maxPrice = num;
    }

    final filters = ParsedFilters(
      areaCode: areaCode,
      governorateCode: governorateCode,
      serviceType: serviceType,
      propertyType: propertyType,
      maxPrice: maxPrice,
    );

    final canRunQuery = filters.hasArea;

    return ConversationalSearchResult(
      filters: filters,
      clarificationQuestions: clarificationQuestions,
      canRunQuery: canRunQuery,
    );
  }

  /// يبني استعلام Firestore بسيطاً: approved + areaCode + ترتيب بالتاريخ.
  /// باقي الفلاتر (نوع الخدمة، نوع العقار، المحافظة، الغرف) تُطبَّق في الذاكرة
  /// لتجنّب فهارس مركبة كثيرة وأخطاء failed-precondition.
  Query<Map<String, dynamic>> buildQuery(ParsedFilters filters) {
    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection('properties')
        .where('approved', isEqualTo: true);

    if (filters.areaCode != null && filters.areaCode!.isNotEmpty) {
      q = q.where('areaCode', isEqualTo: filters.areaCode);
    }

    return q.orderBy('createdAt', descending: true);
  }

  /// تطابق الوثيقة مع فلاتر المحادثة (بعد الجلب من Firestore).
  bool documentMatchesConversationFilters(
    Map<String, dynamic> data,
    Map<String, dynamic> filters,
  ) {
    final governorateCode = filters['governorateCode']?.toString().trim() ?? '';
    if (governorateCode.isNotEmpty && governorateCode != 'chalet') {
      if ((data['governorateCode']?.toString() ?? '') != governorateCode) {
        return false;
      }
    }
    final serviceType = filters['serviceType']?.toString().trim() ?? '';
    if (serviceType.isNotEmpty) {
      if ((data['serviceType']?.toString() ?? '') != serviceType) return false;
    }
    final type = filters['type']?.toString().trim() ?? '';
    if (type.isNotEmpty) {
      if ((data['type']?.toString() ?? '') != type) return false;
    }
    final bedrooms = filters['bedrooms'];
    final br = bedrooms is int
        ? bedrooms
        : (bedrooms != null ? int.tryParse(bedrooms.toString()) : null);
    if (br != null && br > 0) {
      final rc = data['roomCount'];
      final n = rc is int ? rc : int.tryParse(rc?.toString() ?? '') ?? -1;
      if (n != br) return false;
    }
    return true;
  }

  /// يبني استعلام من خريطة فلاتر (من الـ Agent): areaCode, type, serviceType, budget, bedrooms
  Query<Map<String, dynamic>> buildQueryFromMap(Map<String, dynamic> filters) {
    final areaCode = filters['areaCode']?.toString().trim();
    final type = filters['type']?.toString().trim();
    final serviceType = filters['serviceType']?.toString().trim();
    final budget = filters['budget'] is num ? (filters['budget'] as num).toDouble() : (filters['budget'] != null ? double.tryParse(filters['budget'].toString()) : null);
    final bedrooms = filters['bedrooms'] is int ? filters['bedrooms'] as int : (filters['bedrooms'] != null ? int.tryParse(filters['bedrooms'].toString()) : null);
    final governorateCode = filters['governorateCode']?.toString().trim();
    return buildQuery(ParsedFilters(
      areaCode: areaCode?.isNotEmpty == true ? areaCode : null,
      governorateCode: governorateCode?.isNotEmpty == true ? governorateCode : null,
      serviceType: serviceType?.isNotEmpty == true ? serviceType : null,
      propertyType: type?.isNotEmpty == true ? type : null,
      maxPrice: budget != null && budget > 0 ? budget : null,
      bedrooms: bedrooms != null && bedrooms > 0 ? bedrooms : null,
    ));
  }

  /// استعلام في مناطق قريبة فقط (للـ fallback عند عدم وجود نتائج في المنطقة المطلوبة).
  /// [nearbyAreaCodes] قائمة areaCode للمناطق القريبة (مثلاً ['rawda', 'kaifan', 'khaldiya']).
  /// يرجع استعلام بحد أقصى 3 نتائج، الأحدث أولاً.
  Query<Map<String, dynamic>> buildQueryNearbyFromMap(
    Map<String, dynamic> filters,
    List<String> nearbyAreaCodes,
  ) {
    if (nearbyAreaCodes.isEmpty) {
      return buildQueryFromMap(filters).limit(0);
    }

    Query<Map<String, dynamic>> q = FirebaseFirestore.instance
        .collection('properties')
        .where('approved', isEqualTo: true)
        .where(
          'areaCode',
          whereIn: nearbyAreaCodes.length > 10
              ? nearbyAreaCodes.sublist(0, 10)
              : nearbyAreaCodes,
        );

    return q.orderBy('createdAt', descending: true).limit(80);
  }
}
