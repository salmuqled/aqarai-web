import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/notification_learning_factors.dart';
import 'package:aqarai_app/services/smart_notification_service.dart';

/// تقدير أداء نصوص الإشعارات: سجلات مشابهة + إرشاديات بأوزان من `notification_learning`.
abstract final class NotificationPredictionService {
  static const Map<String, double> _defaultWeights = {
    'hasEmoji': 0.1,
    'hasArea': 0.2,
    'hasUrgency': 0.15,
    'shortText': 0.05,
  };

  static const double _heuristicBase = 0.28;

  /// نص موحّد للمقارنة مع السجلات ومع النسخ المُمرَّرة.
  static String canonicalVariantText(String title, String body) {
    return '${title.trim()}\n${body.trim()}';
  }

  /// تحميل أوزان التعلّم؛ عند الفشل تُستخدم الأوزان الافتراضية.
  static Future<Map<String, double>> fetchLearningWeights(
    FirebaseFirestore db,
  ) async {
    try {
      final snap = await db.collection('notification_learning').get();
      final out = Map<String, double>.from(_defaultWeights);
      for (final d in snap.docs) {
        final id = d.id;
        if (!out.containsKey(id)) continue;
        final w = d.data()['weight'];
        if (w is num) {
          out[id] = w.toDouble().clamp(0.0, 0.5);
        }
      }
      return out;
    } catch (_) {
      return Map<String, double>.from(_defaultWeights);
    }
  }

  /// عوامل النص لحقل `factors` في السجل.
  static NotificationLearningFactors computeFactors({
    required String text,
    String? areaHint,
    required int medianLen,
  }) {
    final h = areaHint?.trim();
    return NotificationLearningFactors(
      hasEmoji: _hasEmoji(text),
      hasArea: h != null && h.isNotEmpty && text.contains(h),
      hasUrgency: _hasUrgencyCue(text),
      shortText: text.isNotEmpty && text.length <= medianLen,
    );
  }

  /// ترتيب تنازلي حسب التنبؤ؛ يحمّل الأوزان من Firestore (مع احتياطي آمن).
  static Future<List<PredictedNotification>> predictRankedForSuggestions({
    required FirebaseFirestore db,
    required List<SmartNotificationSuggestion> suggestions,
    required Iterable<Map<String, dynamic>> pastLogs,
    String? areaNameAr,
  }) async {
    if (suggestions.isEmpty) return [];

    final weights = await fetchLearningWeights(db);
    final texts = suggestions
        .map((s) => canonicalVariantText(s.title, s.body))
        .toList();
    final lengths = texts.map((t) => t.length).toList();
    final medianLen = _median(lengths);
    final areaHint = areaNameAr?.trim();

    final rows = <_ScoredRow>[];
    for (var i = 0; i < suggestions.length; i++) {
      final s = suggestions[i];
      final text = texts[i];
      final norm = _normalize(text);
      final factors = computeFactors(
        text: text,
        areaHint: areaHint,
        medianLen: medianLen,
      );

      double raw;
      final fromLog = _ctrFromSimilarPast(norm, pastLogs);
      if (fromLog != null) {
        raw = fromLog.clamp(0.0, 1.0);
      } else {
        raw = _heuristicRawFromFactors(factors, weights);
      }

      rows.add(
        _ScoredRow(
          text: text,
          raw: raw,
          factors: factors,
          variantId: s.variantId,
        ),
      );
    }

    rows.sort((a, b) => b.raw.compareTo(a.raw));

    final raws = rows.map((e) => e.raw).toList();
    final minR = raws.reduce((a, b) => a < b ? a : b);
    final maxR = raws.reduce((a, b) => a > b ? a : b);

    return rows
        .map((e) {
          final normCtr = maxR > minR
              ? ((e.raw - minR) / (maxR - minR)).clamp(0.0, 1.0)
              : 0.5;
          return PredictedNotification(
            text: e.text,
            predictedCTR: normCtr,
            predictedScore: e.raw,
            factors: e.factors,
            variantId: e.variantId,
          );
        })
        .toList();
  }

  /// واجهة قديمة: أوزان افتراضية ثابتة (اختبارات / بدون Firestore).
  static List<PredictedNotification> predictBestVariants({
    required List<String> variants,
    required Iterable<Map<String, dynamic>> pastLogs,
    String? areaNameAr,
  }) {
    if (variants.isEmpty) return [];

    final weights = Map<String, double>.from(_defaultWeights);
    final areaHint = areaNameAr?.trim();
    final lengths = variants.map((v) => v.length).toList();
    final medianLen = _median(lengths);

    final rows = <_ScoredRow>[];
    for (final text in variants) {
      final norm = _normalize(text);
      final factors = computeFactors(
        text: text,
        areaHint: areaHint,
        medianLen: medianLen,
      );

      double raw;
      final fromLog = _ctrFromSimilarPast(norm, pastLogs);
      if (fromLog != null) {
        raw = fromLog.clamp(0.0, 1.0);
      } else {
        raw = _heuristicRawFromFactors(factors, weights);
      }
      rows.add(
        _ScoredRow(
          text: text,
          raw: raw,
          factors: factors,
          variantId: null,
        ),
      );
    }

    rows.sort((a, b) => b.raw.compareTo(a.raw));
    final raws = rows.map((e) => e.raw).toList();
    final minR = raws.reduce((a, b) => a < b ? a : b);
    final maxR = raws.reduce((a, b) => a > b ? a : b);

    return rows
        .map((e) {
          final normCtr = maxR > minR
              ? ((e.raw - minR) / (maxR - minR)).clamp(0.0, 1.0)
              : 0.5;
          return PredictedNotification(
            text: e.text,
            predictedCTR: normCtr,
            predictedScore: e.raw,
            factors: e.factors,
            variantId: e.variantId,
          );
        })
        .toList();
  }

  static double _heuristicRawFromFactors(
    NotificationLearningFactors f,
    Map<String, double> w,
  ) {
    var s = _heuristicBase;
    if (f.hasEmoji) s += w['hasEmoji'] ?? _defaultWeights['hasEmoji']!;
    if (f.hasArea) s += w['hasArea'] ?? _defaultWeights['hasArea']!;
    if (f.hasUrgency) {
      s += w['hasUrgency'] ?? _defaultWeights['hasUrgency']!;
    }
    if (f.shortText) {
      s += w['shortText'] ?? _defaultWeights['shortText']!;
    }
    return s.clamp(0.0, 1.0);
  }

  static double? _ctrFromSimilarPast(
    String variantNorm,
    Iterable<Map<String, dynamic>> pastLogs,
  ) {
    const threshold = 0.52;
    double bestSim = threshold;
    double? bestCtr;
    var bestSent = -1;

    for (final m in pastLogs) {
      final sent = _readInt(m['sentCount']);
      if (sent <= 0) continue;

      final vt = m['variantText']?.toString().trim();
      final title = m['title']?.toString().trim() ?? '';
      final body = m['body']?.toString().trim() ?? '';
      final logText = (vt != null && vt.isNotEmpty)
          ? vt
          : canonicalVariantText(title, body);
      if (logText.isEmpty) continue;

      final logNorm = _normalize(logText);
      final sim = _similarity(variantNorm, logNorm);
      if (sim < threshold) continue;

      final clicks = _readInt(m['clickCount']);
      final ctr = clicks / sent;

      if (sim > bestSim + 1e-6 ||
          (sim >= bestSim - 1e-6 && sent > bestSent)) {
        bestSim = sim;
        bestCtr = ctr;
        bestSent = sent;
      }
    }
    return bestCtr;
  }

  static bool _hasEmoji(String s) {
    for (final r in s.runes) {
      if (r >= 0x1F300 && r <= 0x1FAFF) return true;
      if (r >= 0x2600 && r <= 0x27BF) return true;
    }
    return false;
  }

  static bool _hasUrgencyCue(String s) {
    return s.contains('🔥') || s.contains('📈');
  }

  static String _normalize(String s) {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.contains(b) || b.contains(a)) {
      final shorter = a.length < b.length ? a : b;
      if (shorter.length >= 12) return 0.92;
      if (shorter.length >= 6) return 0.78;
    }
    final ta = a
        .split(RegExp(r'[\s\n،.،؛]+'))
        .where((w) => w.length > 1)
        .toSet();
    final tb = b
        .split(RegExp(r'[\s\n،.،؛]+'))
        .where((w) => w.length > 1)
        .toSet();
    if (ta.isEmpty || tb.isEmpty) return 0;
    final inter = ta.intersection(tb).length;
    final union = ta.union(tb).length;
    return union == 0 ? 0 : inter / union;
  }

  static int _median(List<int> values) {
    if (values.isEmpty) return 0;
    final v = List<int>.from(values)..sort();
    final mid = v.length ~/ 2;
    if (v.length.isOdd) return v[mid];
    return ((v[mid - 1] + v[mid]) / 2).round();
  }

  static int _readInt(dynamic v) {
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }
}

class PredictedNotification {
  const PredictedNotification({
    required this.text,
    required this.predictedCTR,
    required this.predictedScore,
    required this.factors,
    this.variantId,
  });

  final String text;
  final double predictedCTR;

  /// درجة خام قبل التطبيع (تُخزَّن في `predictedScore` بالسجل).
  final double predictedScore;
  final NotificationLearningFactors factors;
  final String? variantId;
}

class _ScoredRow {
  _ScoredRow({
    required this.text,
    required this.raw,
    required this.factors,
    this.variantId,
  });

  final String text;
  final double raw;
  final NotificationLearningFactors factors;
  final String? variantId;
}
