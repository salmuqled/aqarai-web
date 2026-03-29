import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/listing_enums.dart';

/// Multi-view, weighted lead attribution for a single property.
///
/// Uses the **50 most recent** `property_views` rows (caller applies `limit(50)`
/// and should order by `viewedAt` desc). Scores each canonical source as
/// `count × weight`, then breaks ties using strict business priority.
abstract final class LeadSourceAttribution {
  /// Tie-break order when two sources have the same score (higher priority = earlier).
  static const List<String> _priorityOrder = [
    DealLeadSource.aiChat,
    DealLeadSource.featured,
    DealLeadSource.search,
    DealLeadSource.direct,
    DealLeadSource.unknown,
  ];

  /// Optional weights: stronger channels outweigh many weak touches.
  static int _weight(String normalized) {
    switch (normalized) {
      case DealLeadSource.aiChat:
        return 5;
      case DealLeadSource.featured:
        return 3;
      case DealLeadSource.search:
        return 2;
      case DealLeadSource.direct:
        return 1;
      default:
        return 0;
    }
  }

  static int _priorityIndex(String normalized) {
    final i = _priorityOrder.indexOf(normalized);
    return i >= 0 ? i : _priorityOrder.length;
  }

  /// Map raw Firestore field to a bucket we aggregate on.
  static String normalizeViewLeadSource(Map<String, dynamic>? data) {
    if (data == null) return DealLeadSource.unknown;
    final raw = data['leadSource']?.toString().trim();
    if (raw == null || raw.isEmpty) return DealLeadSource.unknown;
    if (DealLeadSource.isAttributionSource(raw)) return raw;
    if (raw == DealLeadSource.unknown) return DealLeadSource.unknown;
    return DealLeadSource.unknown;
  }

  /// Picks the winning source from up to 50 recent view documents.
  ///
  /// - Empty list → [DealLeadSource.unknown]
  /// - Only unknown / missing fields → unknown
  /// - Otherwise: max `(count × weight)`; ties → [_priorityOrder]
  static String resolveLeadSource(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> views,
  ) {
    if (views.isEmpty) return DealLeadSource.unknown;

    final counts = <String, int>{};
    for (final doc in views) {
      try {
        final key = normalizeViewLeadSource(doc.data());
        counts[key] = (counts[key] ?? 0) + 1;
      } catch (_) {
        counts[DealLeadSource.unknown] =
            (counts[DealLeadSource.unknown] ?? 0) + 1;
      }
    }

    var best = DealLeadSource.unknown;
    var bestScore = -1;

    for (final e in counts.entries) {
      final source = e.key;
      final score = e.value * _weight(source);

      if (score > bestScore) {
        bestScore = score;
        best = source;
      } else if (score == bestScore && score >= 0) {
        if (_priorityIndex(source) < _priorityIndex(best)) {
          best = source;
        }
      }
    }

    if (bestScore <= 0) return DealLeadSource.unknown;
    return best;
  }
}
