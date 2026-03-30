import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/decision_accuracy_snapshot.dart';
import 'package:aqarai_app/services/decision_tracking_service.dart';

/// Dashboard: trust in auto marketing decisions (accepted vs modified).
class AdminDecisionAccuracySection extends StatelessWidget {
  const AdminDecisionAccuracySection({super.key, required this.isAr});

  final bool isAr;

  String _fmtPct(double x) => (x * 100).clamp(0, 100).toStringAsFixed(0);

  /// [deltaPct] is (actual − expected) × 100 (percentage points on CTR).
  String _signedPct(double deltaPct) {
    if (deltaPct >= 0) {
      return '+${deltaPct.round()}';
    }
    return '${deltaPct.round()}';
  }

  String _partLabel(AppLocalizations loc, String? key) {
    switch (key) {
      case 'caption':
        return loc.adminDecisionPartCaption;
      case 'audience':
        return loc.adminDecisionPartAudience;
      case 'time':
        return loc.adminDecisionPartTime;
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return StreamBuilder<DecisionAccuracySnapshot>(
      stream: DecisionTrackingService.watchDecisionAccuracy(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              isAr
                  ? 'تعذّر تحميل دقة القرارات.'
                  : 'Could not load decision accuracy.',
              style: TextStyle(color: Colors.red.shade800, fontSize: 13),
            ),
          );
        }

        final d = snap.data ?? DecisionAccuracySnapshot.empty;
        final total = d.totalDecisions;
        final accPct = _fmtPct(d.acceptedRate);
        final modPct = _fmtPct(d.modifiedRate);
        final top = d.mostOverriddenKey();
        final capT = _fmtPct(d.captionTrust);
        final timeT = _fmtPct(d.timeTrust);
        final audT = _fmtPct(d.audienceTrust);
        final weak = d.dimensionTrust.weakestKey();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              loc.adminDecisionAccuracyTitle,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              loc.adminDecisionAccuracySubtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
            if (d.autoShieldEnabled) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade700, width: 1.2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loc.hybridAutoShieldPausedTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: Colors.red.shade900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      loc.hybridAutoShieldPausedBody,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: Colors.red.shade900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              loc.adminDecisionSystemTrustTitle,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.blueGrey.shade900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              loc.adminDecisionTrustCaptionLine(capT),
              style: TextStyle(
                fontSize: 14,
                fontWeight: weak == 'caption' ? FontWeight.w800 : FontWeight.w500,
                color: weak == 'caption'
                    ? Colors.deepOrange.shade900
                    : Colors.grey.shade900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              loc.adminDecisionTrustTimeLine(timeT),
              style: TextStyle(
                fontSize: 14,
                fontWeight: weak == 'time' ? FontWeight.w800 : FontWeight.w500,
                color: weak == 'time'
                    ? Colors.deepOrange.shade900
                    : Colors.grey.shade900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              loc.adminDecisionTrustAudienceLine(audT),
              style: TextStyle(
                fontSize: 14,
                fontWeight:
                    weak == 'audience' ? FontWeight.w800 : FontWeight.w500,
                color: weak == 'audience'
                    ? Colors.deepOrange.shade900
                    : Colors.grey.shade900,
              ),
            ),
            if (weak != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade700, width: 1.2),
                ),
                child: Text(
                  loc.adminDecisionWeakestLine(_partLabel(loc, weak)),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber.shade900,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              loc.adminDecisionOutcomeTitle,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.blueGrey.shade900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              loc.adminDecisionOutcomeSubtitle,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 8),
            if (d.outcomeLearningDeltaPct != null &&
                d.outcomeLearningBeatExpectation != null) ...[
              Text(
                d.outcomeLearningBeatExpectation!
                    ? loc.adminDecisionOutcomeBeat(_signedPct(d.outcomeLearningDeltaPct!))
                    : loc.adminDecisionOutcomeMiss(_signedPct(d.outcomeLearningDeltaPct!)),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: d.outcomeLearningBeatExpectation!
                      ? Colors.green.shade800
                      : Colors.red.shade800,
                ),
              ),
            ] else
              Text(
                loc.adminDecisionOutcomeWaiting,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            const SizedBox(height: 14),
            if (total <= 0)
              Text(
                loc.adminDecisionNoLogs,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
              )
            else ...[
              Text(
                loc.adminDecisionAcceptedPct(accPct),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.green.shade800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                loc.adminDecisionModifiedPct(modPct),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange.shade900,
                ),
              ),
              if (top != null && d.overrideCount > 0) ...[
                const SizedBox(height: 8),
                Text(
                  loc.adminDecisionMostOverridden(_partLabel(loc, top)),
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                ),
              ],
            ],
          ],
        );
      },
    );
  }
}
