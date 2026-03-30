import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/models/caption_learning_weights.dart';

/// Reads [caption_learning] docs (`emoji`, `area`, `urgency`, `short_text`).
abstract final class CaptionLearningService {
  CaptionLearningService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static double _readWeight(DocumentSnapshot<Map<String, dynamic>>? snap, double fallback) {
    if (snap == null || !snap.exists) return fallback;
    final w = snap.data()?['weight'];
    if (w is num && w.isFinite) {
      return w.toDouble().clamp(0.0, 0.5);
    }
    return fallback;
  }

  static Future<CaptionLearningWeights> getWeights() async {
    try {
      final docs = await Future.wait([
        _db.collection('caption_learning').doc('emoji').get(),
        _db.collection('caption_learning').doc('area').get(),
        _db.collection('caption_learning').doc('urgency').get(),
        _db.collection('caption_learning').doc('short_text').get(),
      ]);
      return CaptionLearningWeights(
        emoji: _readWeight(docs[0], CaptionLearningWeights.defaults.emoji),
        area: _readWeight(docs[1], CaptionLearningWeights.defaults.area),
        urgency: _readWeight(docs[2], CaptionLearningWeights.defaults.urgency),
        shortText: _readWeight(docs[3], CaptionLearningWeights.defaults.shortText),
      );
    } catch (_) {
      return CaptionLearningWeights.defaults;
    }
  }
}
