import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/services/ai_suggestions_auto_config_service.dart';

/// Heuristic: compare AI suggestion metrics before vs after the live config’s [updatedAt].
class AiConfigRollbackSuggestion {
  const AiConfigRollbackSuggestion({
    required this.currentVersion,
    required this.previousVersion,
    required this.previousHistoryDocId,
    required this.ctrBefore,
    required this.ctrAfter,
    required this.convBefore,
    required this.convAfter,
    required this.shownBefore,
    required this.shownAfter,
  });

  final int currentVersion;
  final int previousVersion;
  final String previousHistoryDocId;

  final double? ctrBefore;
  final double? ctrAfter;
  final double? convBefore;
  final double? convAfter;
  final int shownBefore;
  final int shownAfter;
}

abstract final class AiSuggestionsRollbackSuggestionService {
  AiSuggestionsRollbackSuggestionService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const int _baselineDays = 7;
  static const int _minShownPerPeriod = 120;
  static const int _minClickedForConv = 40;
  static const int _minDaysAfterChange = 2;

  /// Relative drop (e.g. 0.2 => post ≤ pre × 0.8) or absolute [absDrop] counts as “significant”.
  static const double _relDrop = 0.20;
  static const double _ctrAbsDrop = 0.012;
  static const double _convAbsDrop = 0.025;
  static const double _minCtrForSignal = 0.025;
  static const double _minConvForSignal = 0.04;

  static String _yyyymmddUtc(DateTime d) {
    final u = d.toUtc();
    final y = u.year.toString().padLeft(4, '0');
    final m = u.month.toString().padLeft(2, '0');
    final day = u.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static String _addDaysYmd(String ymd, int deltaDays) {
    final parts = ymd.split('-').map(int.parse).toList();
    final d = DateTime.utc(parts[0], parts[1], parts[2]);
    final n = d.add(Duration(days: deltaDays));
    return _yyyymmddUtc(n);
  }

  static int _dayDiffUtc(String endYmd, String startYmd) {
    final pe = startYmd.split('-').map(int.parse).toList();
    final pend = endYmd.split('-').map(int.parse).toList();
    final a = DateTime.utc(pe[0], pe[1], pe[2]);
    final b = DateTime.utc(pend[0], pend[1], pend[2]);
    return b.difference(a).inDays;
  }

  static bool _significantRateDrop(double? pre, double? post, double absDrop) {
    if (pre == null || post == null || pre <= 0) return false;
    if (post <= pre * (1 - _relDrop)) return true;
    if (post <= pre - absDrop) return true;
    return false;
  }

  static Future<String?> _findHistoryDocForVersion(int version) async {
    if (version < 1) return null;
    final qs = await _db
        .collection('ai_config_history')
        .where('configVersion', isEqualTo: version)
        .limit(1)
        .get();
    if (qs.docs.isEmpty) return null;
    return qs.docs.first.id;
  }

  /// Returns a suggestion when metrics after the last config change look materially
  /// worse than the prior baseline window, and a history doc exists for [version - 1].
  static Future<AiConfigRollbackSuggestion?> evaluate(
    AiSuggestionsAutoConfig config,
  ) async {
    final v = config.configVersion;
    if (v <= 1) return null;

    final updatedAt = config.updatedAt;
    if (updatedAt == null) return null;

    final changeDayUtc = _yyyymmddUtc(updatedAt);
    final todayUtc = _yyyymmddUtc(DateTime.now());
    if (_dayDiffUtc(todayUtc, changeDayUtc) < _minDaysAfterChange) {
      return null;
    }

    final preEnd = _addDaysYmd(changeDayUtc, -1);
    final preStart = _addDaysYmd(changeDayUtc, -_baselineDays);

    final preSnap = await _loadTotalsForDayRange(preStart, preEnd);
    final postSnap = await _loadTotalsForDayRange(changeDayUtc, todayUtc);

    final shownB = preSnap.shown;
    final clickB = preSnap.clicked;
    final conversionsB = preSnap.conversions;
    final shownA = postSnap.shown;
    final clickA = postSnap.clicked;
    final conversionsA = postSnap.conversions;

    if (shownB < _minShownPerPeriod || shownA < _minShownPerPeriod) {
      return null;
    }

    final ctrB = shownB <= 0 ? null : clickB / shownB;
    final ctrA = shownA <= 0 ? null : clickA / shownA;
    final convRateB = clickB <= 0 ? null : conversionsB / clickB;
    final convRateA = clickA <= 0 ? null : conversionsA / clickA;

    final ctrDrop = ctrB != null &&
        ctrA != null &&
        ctrB >= _minCtrForSignal &&
        _significantRateDrop(ctrB, ctrA, _ctrAbsDrop);

    final convDrop = clickB >= _minClickedForConv &&
        clickA >= _minClickedForConv &&
        convRateB != null &&
        convRateA != null &&
        convRateB >= _minConvForSignal &&
        _significantRateDrop(convRateB, convRateA, _convAbsDrop);

    if (!ctrDrop && !convDrop) return null;

    final prevDocId = await _findHistoryDocForVersion(v - 1);
    if (prevDocId == null) return null;

    return AiConfigRollbackSuggestion(
      currentVersion: v,
      previousVersion: v - 1,
      previousHistoryDocId: prevDocId,
      ctrBefore: ctrB,
      ctrAfter: ctrA,
      convBefore: convRateB,
      convAfter: convRateA,
      shownBefore: shownB,
      shownAfter: shownA,
    );
  }

  static Future<_Totals> _loadTotalsForDayRange(
    String startDay,
    String endDay,
  ) async {
    if (startDay.compareTo(endDay) > 0) return const _Totals();

    final snap = await _db
        .collection('analytics')
        .where('kind', isEqualTo: 'ai_suggestions_day')
        .where('day', isGreaterThanOrEqualTo: startDay)
        .where('day', isLessThanOrEqualTo: endDay)
        .get();

    var shown = 0;
    var clicked = 0;
    var conversions = 0;
    for (final d in snap.docs) {
      final m = d.data();
      shown += (m['totalShown'] as num?)?.toInt() ?? 0;
      clicked += (m['totalClicked'] as num?)?.toInt() ?? 0;
      conversions += (m['totalConversions'] as num?)?.toInt() ?? 0;
    }
    return _Totals(shown: shown, clicked: clicked, conversions: conversions);
  }
}

class _Totals {
  const _Totals({
    this.shown = 0,
    this.clicked = 0,
    this.conversions = 0,
  });

  final int shown;
  final int clicked;
  final int conversions;
}
