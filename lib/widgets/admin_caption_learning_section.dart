import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';

/// Shows learned factor weights from [caption_learning].
///
/// Uses one [Future] per [State] so dashboard stream rebuilds do not restart
/// the query every frame.
class AdminCaptionLearningSection extends StatefulWidget {
  const AdminCaptionLearningSection({
    super.key,
    required this.isAr,
  });

  final bool isAr;

  @override
  State<AdminCaptionLearningSection> createState() =>
      _AdminCaptionLearningSectionState();
}

class _AdminCaptionLearningSectionState
    extends State<AdminCaptionLearningSection> {
  static const _order = ['emoji', 'area', 'urgency', 'short_text'];

  late final Future<QuerySnapshot<Map<String, dynamic>>> _learningFuture =
      FirebaseFirestore.instance.collection('caption_learning').get();

  String _factorLabel(AppLocalizations loc, String docId) {
    switch (docId) {
      case 'emoji':
        return loc.adminCaptionLearningFactorEmoji;
      case 'area':
        return loc.adminCaptionLearningFactorArea;
      case 'urgency':
        return loc.adminCaptionLearningFactorUrgency;
      case 'short_text':
        return loc.adminCaptionLearningFactorShort;
      default:
        return docId;
    }
  }

  String _emojiFor(String docId) {
    switch (docId) {
      case 'emoji':
        return '🔥';
      case 'area':
        return '📍';
      case 'urgency':
        return '⚡';
      case 'short_text':
        return '📏';
      default:
        return '📊';
    }
  }

  static double _defaultWeight(String id) {
    switch (id) {
      case 'emoji':
        return 0.1;
      case 'area':
        return 0.2;
      case 'urgency':
        return 0.2;
      case 'short_text':
        return 0.1;
      default:
        return 0.1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: _learningFuture,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              widget.isAr
                  ? 'تعذّر تحميل بيانات التعلّم.'
                  : 'Could not load learning weights.',
              style: TextStyle(color: Colors.red.shade800, fontSize: 13),
            ),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final byId = <String, Map<String, dynamic>>{};
        for (final d in snap.data?.docs ?? const []) {
          byId[d.id] = d.data();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.adminCaptionLearningTitle,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              loc.adminCaptionLearningSubtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 10),
            ..._order.map((id) {
              final data = byId[id];
              final w = (data?['weight'] is num)
                  ? (data!['weight'] as num).toDouble().clamp(0.0, 0.5)
                  : _defaultWeight(id);
              final pct = (w * 100).round();
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${_emojiFor(id)} ${_factorLabel(loc, id)} → +$pct%',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
