import 'package:cloud_firestore/cloud_firestore.dart';

/// اقتراح نص لإشعار موحّد (عام)؛ [variantId] يُستخدم في اختبارات A/B.
class SmartNotificationSuggestion {
  const SmartNotificationSuggestion({
    required this.title,
    required this.body,
    this.variantId,
  });

  final String title;
  final String body;

  /// معرّف ثابت للنسخة (مثل `v0` …) عند إرسال عدة نصوص في حملة واحدة.
  final String? variantId;
}

/// مخرجات المحرك: بث عام + عينة مخصصة + سياق للـ Cloud Function.
class SmartNotificationBundle {
  const SmartNotificationBundle({
    required this.broadcastVariants,
    required this.personalizedSampleTitle,
    required this.personalizedSampleBody,
    required this.trendingAreaAr,
    required this.trendingAreaEn,
    required this.dominantPropertyKind,
    required this.interestWeighted,
    required this.urgent,
  });

  /// عدة نصوص للبث العام لاختبار A/B (مجموعة واحدة لكل حملة).
  final List<SmartNotificationSuggestion> broadcastVariants;

  /// يُعرض في المعاينة كمثال للإرسال المخصّص (الحقيقي يُبنى لكل مستخدم على السيرفر).
  final String personalizedSampleTitle;
  final String personalizedSampleBody;

  /// يُمرَّر لـ [sendPersonalizedNotifications] لمن لا يملك preferredArea.
  final String trendingAreaAr;
  final String trendingAreaEn;

  /// أحد: house | apartment | land | chalet | other
  final String dominantPropertyKind;

  /// true إذا اعتمدنا وزن المشاهدات (إقبال) أكثر من الصفقات.
  final bool interestWeighted;

  /// طبقة عاجلة (إقبال مرتفع).
  final bool urgent;
}

class _AreaPair {
  _AreaPair({required this.ar, required this.en});
  final String ar;
  final String en;
}

/// يولّد نصوص إشعارات من عيّنتي [deals] و [property_views] بدون استعلامات إضافية.
/// المشاهدات تُربَط بالمنطقة عبر `propertyId` الموجود في صفقات العيّنة.
///
/// ترتيب «أفضل تنبؤ» يُحسب عند المعاينة (`notification_prediction_service`) وليس هنا.
abstract final class SmartNotificationService {
  static const double _viewsVsDealsRatio = 1.25;
  static const int _minViewsForInterest = 3;
  static const int _urgentViewThreshold = 12;

  static SmartNotificationBundle generateFromData({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> deals,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> views,
    required bool isAr,
  }) {
    final propertyAreas = _propertyIdToArea(deals);
    final dealAreaCounts = _countAreasFromDeals(deals);
    final viewAreaCounts = _countAreasFromViews(views, propertyAreas);

    final topKind = _topPropertyKind(deals);
    final kindStr = _kindToApi(topKind?.kind ?? _PropKind.other);

    _AreaPick? pick = _pickTrendingArea(
      dealAreaCounts,
      viewAreaCounts,
      propertyAreas,
    );

    if (pick == null || pick.labelAr.isEmpty) {
      return _bundleFromTypeOrFallback(
        topKind,
        kindStr,
        isAr,
        interestWeighted: false,
        urgent: false,
      );
    }

    final interestWeighted = pick.interestWeighted;
    final urgent =
        interestWeighted && pick.viewCount >= _urgentViewThreshold;

    final broadcastVariants = _broadcastVariantsFromArea(
      pick: pick,
      isAr: isAr,
      interestWeighted: interestWeighted,
      urgent: urgent,
      kind: topKind?.kind ?? _PropKind.other,
    );

    final sample = _personalizedSample(
      areaAr: pick.labelAr,
      areaEn: pick.labelEn,
      kind: topKind?.kind ?? _PropKind.other,
      isAr: isAr,
    );

    return SmartNotificationBundle(
      broadcastVariants: broadcastVariants,
      personalizedSampleTitle: sample.title,
      personalizedSampleBody: sample.body,
      trendingAreaAr: pick.labelAr,
      trendingAreaEn: pick.labelEn.isNotEmpty ? pick.labelEn : pick.labelAr,
      dominantPropertyKind: kindStr,
      interestWeighted: interestWeighted,
      urgent: urgent,
    );
  }

  // --- propertyId → منطقة (من عيّنة الصفقات فقط) ---

  static Map<String, _AreaPair> _propertyIdToArea(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> deals,
  ) {
    final map = <String, _AreaPair>{};
    for (final d in deals) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final pid = (m['propertyId'] ?? '').toString().trim();
      if (pid.isEmpty) continue;
      final ar = (m['areaAr'] ?? m['area'] ?? '').toString().trim();
      if (ar.isEmpty || ar == '—') continue;
      final en = (m['areaEn'] ?? '').toString().trim();
      map[pid] = _AreaPair(ar: ar, en: en);
    }
    return map;
  }

  static Map<String, int> _countAreasFromDeals(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> deals,
  ) {
    final counts = <String, int>{};
    for (final d in deals) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final ar = (m['areaAr'] ?? m['area'] ?? '').toString().trim();
      if (ar.isEmpty || ar == '—') continue;
      counts[ar] = (counts[ar] ?? 0) + 1;
    }
    return counts;
  }

  static Map<String, int> _countAreasFromViews(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> views,
    Map<String, _AreaPair> propertyAreas,
  ) {
    final counts = <String, int>{};
    for (final v in views) {
      Map<String, dynamic> m;
      try {
        m = v.data();
      } catch (_) {
        continue;
      }
      final pid = (m['propertyId'] ?? '').toString().trim();
      if (pid.isEmpty) continue;
      final pair = propertyAreas[pid];
      if (pair == null || pair.ar.isEmpty) continue;
      counts[pair.ar] = (counts[pair.ar] ?? 0) + 1;
    }
    return counts;
  }

  /// إن كان المشاهدات >> الصفقات للمنطقة الأكثر مشاهدة نستخدم منطق «إقبال».
  static _AreaPick? _pickTrendingArea(
    Map<String, int> dealCounts,
    Map<String, int> viewCounts,
    Map<String, _AreaPair> propertyAreas,
  ) {
    if (dealCounts.isEmpty && viewCounts.isEmpty) return null;

    String? topViewArea;
    var maxV = 0;
    viewCounts.forEach((a, c) {
      if (c > maxV) {
        maxV = c;
        topViewArea = a;
      }
    });

    String? topDealArea;
    var maxD = 0;
    dealCounts.forEach((a, c) {
      if (c > maxD) {
        maxD = c;
        topDealArea = a;
      }
    });

    final candidates = <String>{...dealCounts.keys, ...viewCounts.keys};
    if (candidates.isEmpty) return null;

    String chosenAr;
    bool interestWeighted;
    int vc;
    int dc;

    if (topViewArea != null &&
        maxV >= _minViewsForInterest &&
        maxV > (dealCounts[topViewArea!] ?? 0) * _viewsVsDealsRatio) {
      chosenAr = topViewArea!;
      interestWeighted = true;
      vc = maxV;
      dc = dealCounts[chosenAr] ?? 0;
    } else if (topDealArea != null && maxD > 0) {
      chosenAr = topDealArea!;
      interestWeighted = false;
      dc = maxD;
      vc = viewCounts[chosenAr] ?? 0;
    } else if (topViewArea != null && maxV > 0) {
      chosenAr = topViewArea!;
      interestWeighted = true;
      vc = maxV;
      dc = dealCounts[chosenAr] ?? 0;
    } else {
      return null;
    }

    final en = _areaEnFor(chosenAr, propertyAreas);
    return _AreaPick(
      labelAr: chosenAr,
      labelEn: en,
      viewCount: vc,
      dealCount: dc,
      interestWeighted: interestWeighted,
    );
  }

  static String _areaEnFor(
    String areaAr,
    Map<String, _AreaPair> propertyAreas,
  ) {
    for (final p in propertyAreas.values) {
      if (p.ar == areaAr && p.en.isNotEmpty) return p.en;
    }
    return '';
  }

  static List<SmartNotificationSuggestion> _broadcastVariantsFromArea({
    required _AreaPick pick,
    required bool isAr,
    required bool interestWeighted,
    required bool urgent,
    required _PropKind kind,
  }) {
    final emoji = _emojiForKind(kind);
    final ar = pick.labelAr;
    final en = pick.labelEn.isNotEmpty ? pick.labelEn : ar;

    if (urgent && isAr) {
      final titles = [
        '🔥 إقبال عالي على $ar',
        '📈 طلب مرتفع في $ar',
        '👀 نشاط قوي في $ar',
      ];
      final body = '$emoji اكتشف أحدث العقارات في $ar — الطلب مرتفع!';
      return List.generate(
        titles.length,
        (i) => SmartNotificationSuggestion(
          title: titles[i],
          body: body,
          variantId: 'v$i',
        ),
      );
    }
    if (urgent && !isAr) {
      final titles = [
        '🔥 High demand in $en',
        '📈 Strong interest in $en',
        '👀 Active buyers in $en',
      ];
      final body =
          '$emoji Discover the latest listings in $en — demand is high!';
      return List.generate(
        titles.length,
        (i) => SmartNotificationSuggestion(
          title: titles[i],
          body: body,
          variantId: 'v$i',
        ),
      );
    }

    if (interestWeighted) {
      final templatesAr = [
        (String a) => '🔥 اهتمام قوي بعقارات $a',
        (String a) => '📈 مشاهدات مرتفعة في $a',
        (String a) => '👀 الجمهور يتفاعل مع $a',
      ];
      final templatesEn = [
        (String a) => '🔥 Strong interest in $a',
        (String a) => '📈 High engagement in $a',
        (String a) => '👀 Buyers are active in $a',
      ];
      if (isAr) {
        return List.generate(
          templatesAr.length,
          (i) => SmartNotificationSuggestion(
            title: templatesAr[i](ar),
            body: '$emoji تصفّح أحدث العروض في $ar الآن',
            variantId: 'v$i',
          ),
        );
      }
      return List.generate(
        templatesEn.length,
        (i) => SmartNotificationSuggestion(
          title: templatesEn[i](en),
          body: '$emoji Browse fresh listings in $en now.',
          variantId: 'v$i',
        ),
      );
    }

    final templatesAr = [
      (String a) => '🔥 عقارات جديدة في $a',
      (String a) => '🏠 فرص جديدة في $a',
      (String a) => '📈 الطلب مرتفع في $a',
    ];
    final templatesEn = [
      (String a) => '🔥 New properties in $a',
      (String a) => '🏠 Fresh opportunities in $a',
      (String a) => '📈 Strong demand in $a',
    ];
    if (isAr) {
      return List.generate(
        templatesAr.length,
        (i) => SmartNotificationSuggestion(
          title: templatesAr[i](ar),
          body: '🔥 اكتشف أحدث العقارات في $ar الآن',
          variantId: 'v$i',
        ),
      );
    }
    return List.generate(
      templatesEn.length,
      (i) => SmartNotificationSuggestion(
        title: templatesEn[i](en),
        body: '🔥 Discover the latest listings in $en now.',
        variantId: 'v$i',
      ),
    );
  }

  static SmartNotificationSuggestion _personalizedSample({
    required String areaAr,
    required String areaEn,
    required _PropKind kind,
    required bool isAr,
  }) {
    final e = _emojiForKind(kind);
    final en = areaEn.isNotEmpty ? areaEn : areaAr;
    if (isAr) {
      return SmartNotificationSuggestion(
        title: '$e عقارات في $areaAr تناسبك',
        body: '🔥 تصفّح أحدث العروض في $areaAr على عقار أي.',
      );
    }
    return SmartNotificationSuggestion(
      title: '$e Listings in $en tailored for you',
      body: '🔥 See the latest offers in $en on AqarAi.',
    );
  }

  static SmartNotificationBundle _bundleFromTypeOrFallback(
    _TopKind? topKind,
    String kindStr,
    bool isAr, {
    required bool interestWeighted,
    required bool urgent,
  }) {
    if (topKind != null && topKind.count > 0 && topKind.kind != _PropKind.other) {
      final variants = _broadcastVariantsFromPropertyKind(topKind.kind, isAr);
      final sample = _fromPropertyKindPersonalized(topKind.kind, isAr);
      return SmartNotificationBundle(
        broadcastVariants: variants,
        personalizedSampleTitle: sample.title,
        personalizedSampleBody: sample.body,
        trendingAreaAr: '',
        trendingAreaEn: '',
        dominantPropertyKind: kindStr,
        interestWeighted: interestWeighted,
        urgent: urgent,
      );
    }
    final fb = _fallback(isAr);
    return SmartNotificationBundle(
      broadcastVariants: [
        SmartNotificationSuggestion(
          title: fb.title,
          body: fb.body,
          variantId: 'v0',
        ),
      ],
      personalizedSampleTitle: fb.title,
      personalizedSampleBody: fb.body,
      trendingAreaAr: '',
      trendingAreaEn: '',
      dominantPropertyKind: 'other',
      interestWeighted: false,
      urgent: false,
    );
  }

  static List<SmartNotificationSuggestion> _broadcastVariantsFromPropertyKind(
    _PropKind k,
    bool isAr,
  ) {
    String? vid(int i) => 'v$i';

    switch (k) {
      case _PropKind.house:
        final variantsAr = [
          const SmartNotificationSuggestion(
            title: '🏠 بيوت جديدة متوفرة الآن',
            body: '🏠 تصفح أحدث بيوت وفلل على عقار أي.',
          ),
          const SmartNotificationSuggestion(
            title: '🏠 فرص سكنية جديدة',
            body: '🏠 شاهد أحدث البيوت المعروضة اليوم.',
          ),
        ];
        final variantsEn = [
          const SmartNotificationSuggestion(
            title: '🏠 New houses available now',
            body: '🏠 Browse the latest houses and villas on AqarAi.',
          ),
          const SmartNotificationSuggestion(
            title: '🏠 Fresh homes on the market',
            body: '🏠 Check newly listed houses today.',
          ),
        ];
        final list = isAr ? variantsAr : variantsEn;
        return List.generate(
          list.length,
          (i) => SmartNotificationSuggestion(
            title: list[i].title,
            body: list[i].body,
            variantId: vid(i),
          ),
        );
      case _PropKind.apartment:
        final one = isAr
            ? const SmartNotificationSuggestion(
                title: '🏢 شقق جديدة بأسعار مميزة',
                body: '🏢 اكتشف أحدث الشقق والعروض على عقار أي.',
              )
            : const SmartNotificationSuggestion(
                title: '🏢 New apartments at great prices',
                body: '🏢 Discover fresh apartment listings on AqarAi.',
              );
        return [
          SmartNotificationSuggestion(
            title: one.title,
            body: one.body,
            variantId: vid(0),
          ),
        ];
      case _PropKind.land:
        final one = isAr
            ? const SmartNotificationSuggestion(
                title: '🌍 أراضٍ جديدة في السوق',
                body: '🌍 شاهد أحدث قطع الأراضي المتاحة الآن.',
              )
            : const SmartNotificationSuggestion(
                title: '🌍 New land listings',
                body: '🌍 See the latest land plots available now.',
              );
        return [
          SmartNotificationSuggestion(
            title: one.title,
            body: one.body,
            variantId: vid(0),
          ),
        ];
      case _PropKind.chalet:
        final one = isAr
            ? const SmartNotificationSuggestion(
                title: '🏖️ شاليهات جديدة للإيجار',
                body: '🏖️ تصفح أحدث عروض الشاليهات على عقار أي.',
              )
            : const SmartNotificationSuggestion(
                title: '🏖️ New chalets for rent',
                body: '🏖️ Browse fresh chalet offers on AqarAi.',
              );
        return [
          SmartNotificationSuggestion(
            title: one.title,
            body: one.body,
            variantId: vid(0),
          ),
        ];
      case _PropKind.other:
        final fb = _fallback(isAr);
        return [
          SmartNotificationSuggestion(
            title: fb.title,
            body: fb.body,
            variantId: vid(0),
          ),
        ];
    }
  }

  static SmartNotificationSuggestion _fromPropertyKindPersonalized(
    _PropKind k,
    bool isAr,
  ) {
    if (isAr) {
      return SmartNotificationSuggestion(
        title: '${_emojiForKind(k)} عروض تناسب تفضيلاتك',
        body: '🔥 نختار لك إعلانات قريبة من اهتمامك على عقار أي.',
      );
    }
    return SmartNotificationSuggestion(
      title: '${_emojiForKind(k)} Matches for you',
      body: '🔥 Listings aligned with your interests on AqarAi.',
    );
  }

  static SmartNotificationSuggestion _fallback(bool isAr) {
    if (isAr) {
      return const SmartNotificationSuggestion(
        title: '📢 عقارات جديدة',
        body: '📢 عقارات جديدة — تصفح الآن',
      );
    }
    return const SmartNotificationSuggestion(
      title: '📢 New on AqarAi',
      body: '📢 Fresh listings — browse now.',
    );
  }

  static String _emojiForKind(_PropKind k) {
    switch (k) {
      case _PropKind.house:
        return '🏠';
      case _PropKind.apartment:
        return '🏢';
      case _PropKind.land:
        return '🌍';
      case _PropKind.chalet:
        return '🏖️';
      case _PropKind.other:
        return '📢';
    }
  }

  static String _kindToApi(_PropKind k) {
    switch (k) {
      case _PropKind.house:
        return 'house';
      case _PropKind.apartment:
        return 'apartment';
      case _PropKind.land:
        return 'land';
      case _PropKind.chalet:
        return 'chalet';
      case _PropKind.other:
        return 'other';
    }
  }

  static _TopKind? _topPropertyKind(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> deals,
  ) {
    final counts = <_PropKind, int>{
      for (final k in _PropKind.values) k: 0,
    };

    for (final d in deals) {
      Map<String, dynamic> m;
      try {
        m = d.data();
      } catch (_) {
        continue;
      }
      final raw = (m['propertyType'] ?? m['type'] ?? '').toString().trim();
      if (raw.isEmpty || raw == '—') continue;
      final kind = _classifyPropertyType(raw);
      counts[kind] = (counts[kind] ?? 0) + 1;
    }

    _PropKind? bestKind;
    var best = 0;
    counts.forEach((k, v) {
      if (k == _PropKind.other) return;
      if (v > best) {
        best = v;
        bestKind = k;
      }
    });

    if (bestKind == null || best == 0) return null;
    return _TopKind(kind: bestKind!, count: best);
  }

  static _PropKind _classifyPropertyType(String raw) {
    final s = raw.toLowerCase();
    if (s.contains('house') ||
        s.contains('villa') ||
        s.contains('بيت') ||
        s.contains('فيلا') ||
        s.contains('منزل')) {
      return _PropKind.house;
    }
    if (s.contains('apartment') ||
        s.contains('flat') ||
        s.contains('شق') ||
        s.contains('دوبلكس')) {
      return _PropKind.apartment;
    }
    if (s.contains('land') ||
        s.contains('أرض') ||
        s.contains('ارض') ||
        s.contains('plot')) {
      return _PropKind.land;
    }
    if (s.contains('chalet') || s.contains('شاليه')) {
      return _PropKind.chalet;
    }
    return _PropKind.other;
  }
}

class _AreaPick {
  _AreaPick({
    required this.labelAr,
    required this.labelEn,
    required this.viewCount,
    required this.dealCount,
    required this.interestWeighted,
  });

  final String labelAr;
  final String labelEn;
  final int viewCount;
  final int dealCount;
  final bool interestWeighted;
}

enum _PropKind { house, apartment, land, chalet, other }

class _TopKind {
  _TopKind({required this.kind, required this.count});

  final _PropKind kind;
  final int count;
}
