import 'package:aqarai_app/config/caption_tracking_config.dart';

/// Market heat used to pick caption variant.
enum InstagramDemandLevel {
  high,
  medium,
  low,
}

/// Data-driven Instagram captions (manual paste; no Graph API).
abstract final class InstagramCaptionService {
  InstagramCaptionService._();

  /// Builds caption from area, property type, demand signal, and recent deal volume.
  static String generateInstagramCaption({
    required String area,
    required String propertyType,
    required InstagramDemandLevel demandLevel,
    required int recentDealsCount,
    required bool isArabic,
  }) {
    final a = area.trim().isEmpty
        ? (isArabic ? 'الكويت' : 'Kuwait')
        : area.trim();
    final t = propertyType.trim().isEmpty
        ? (isArabic ? 'عقار' : 'property')
        : propertyType.trim();

    final lines = <String>[];

    switch (demandLevel) {
      case InstagramDemandLevel.high:
        if (isArabic) {
          lines.add('🔥 طلب قوي على $t في $a');
          lines.add('');
          lines.add('📊 حركة نشطة في السوق');
          lines.add('🏠 فرص مميزة متاحة الآن');
        } else {
          lines.add('🔥 Strong demand for $t in $a');
          lines.add('');
          lines.add('📊 Active market movement');
          lines.add('🏠 Great opportunities available now');
        }
        break;
      case InstagramDemandLevel.medium:
        if (isArabic) {
          lines.add('📊 فرص متاحة في $a');
          lines.add('');
          lines.add('🏠 $t بأسعار مناسبة');
          lines.add('✨ خيارات متنوعة تناسبك');
        } else {
          lines.add('📊 Opportunities in $a');
          lines.add('');
          lines.add('🏠 $t at attractive prices');
          lines.add('✨ Diverse options for you');
        }
        break;
      case InstagramDemandLevel.low:
        if (isArabic) {
          lines.add('🏠 فرص هادئة في $a');
          lines.add('');
          lines.add('📊 السوق مستقر حالياً');
          lines.add('💡 وقت مناسب للشراء الذكي');
        } else {
          lines.add('🏠 Quieter opportunities in $a');
          lines.add('');
          lines.add('📊 The market is steady right now');
          lines.add('💡 A smart time to buy');
        }
        break;
    }

    if (recentDealsCount > 10) {
      lines.add(
        isArabic
            ? '🔥 تم إغلاق عدة صفقات مؤخراً'
            : '🔥 Several deals closed recently',
      );
    }

    if (_isChaletPropertyType(t)) {
      lines.add(
        isArabic
            ? '🏖️ أجواء مميزة للعطلات'
            : '🏖️ Perfect vibes for getaways',
      );
    }

    lines.add('');
    lines.add(_ctaLine(demandLevel, isArabic));
    lines.add('');
    lines.add(_buildHashtagLine(a, t));

    return lines.join('\n');
  }

  /// CTA + optional trackable link (`cid` = variant) + hashtags (A/B/C bodies).
  static String postFooterSuffix({
    required String area,
    required String propertyType,
    required InstagramDemandLevel demandLevel,
    required bool isArabic,
    String? propertyId,
    String? captionVariantId,
  }) {
    final a = area.trim().isEmpty
        ? (isArabic ? 'الكويت' : 'Kuwait')
        : area.trim();
    final t = propertyType.trim().isEmpty
        ? (isArabic ? 'عقار' : 'property')
        : propertyType.trim();
    final vid = captionVariantId?.trim();
    final linkLine = (vid != null && vid.isNotEmpty)
        ? '\n🔗 ${CaptionTrackingConfig.propertyOpenUrl(propertyId?.trim() ?? '', vid)}'
        : '';
    return '\n${_ctaLine(demandLevel, isArabic)}$linkLine\n\n${_buildHashtagLine(a, t)}';
  }

  static String _ctaLine(InstagramDemandLevel demandLevel, bool isArabic) {
    return switch (demandLevel) {
      InstagramDemandLevel.medium => isArabic
          ? '📲 اكتشف المزيد عبر AqarAi'
          : '📲 Discover more on AqarAi',
      _ => isArabic ? '📲 تصفح عبر AqarAi' : '📲 Browse on AqarAi',
    };
  }

  static bool _isChaletPropertyType(String displayType) {
    final x = displayType.toLowerCase();
    return x.contains('chalet') || displayType.contains('شاليه');
  }

  /// Single line of hashtags; area/type sanitized for Instagram.
  static String _buildHashtagLine(String area, String propertyType) {
    final ta = _hashtagToken(area, fallbackAr: 'الكويت', fallbackEn: 'Kuwait');
    final tt = _hashtagToken(
      propertyType,
      fallbackAr: 'عقار',
      fallbackEn: 'property',
    );
    return '#$ta #$tt #عقار #عقارات_الكويت #AqarAi';
  }

  static String _hashtagToken(
    String raw, {
    required String fallbackAr,
    required String fallbackEn,
  }) {
    var s = raw.trim().replaceFirst(RegExp(r'^#+'), '');
    s = s.replaceAll(RegExp(r'\s+'), '_');
    s = s.replaceAll(RegExp(r'[^\w\u0600-\u06FF_]'), '');
    if (s.isEmpty) {
      return raw.contains(RegExp(r'[\u0600-\u06FF]')) ? fallbackAr : fallbackEn;
    }
    return s;
  }
}
