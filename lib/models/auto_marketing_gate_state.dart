import 'package:aqarai_app/models/auto_decision_trust.dart';

/// Shield + trust snapshot from [auto_decision_learning/state] for hybrid auto gating.
class AutoMarketingGateState {
  const AutoMarketingGateState({
    required this.trust,
    required this.autoShieldEnabled,
    required this.autoFailures,
    required this.autoSuccesses,
    required this.manualRecoveryStreak,
  });

  final AutoDecisionTrust trust;
  final bool autoShieldEnabled;
  final int autoFailures;
  final int autoSuccesses;
  final int manualRecoveryStreak;

  static const AutoMarketingGateState fallback = AutoMarketingGateState(
    trust: AutoDecisionTrust.defaults,
    autoShieldEnabled: false,
    autoFailures: 0,
    autoSuccesses: 0,
    manualRecoveryStreak: 0,
  );

  static AutoMarketingGateState fromStateMap(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return fallback;
    final trust = AutoDecisionTrust.fromStateMap(data);
    final shield = data['autoShieldEnabled'] == true;
    int n(String k) {
      final v = data[k];
      if (v is int) return v;
      if (v is num) return v.round();
      return 0;
    }

    return AutoMarketingGateState(
      trust: trust,
      autoShieldEnabled: shield,
      autoFailures: n('autoFailures'),
      autoSuccesses: n('autoSuccesses'),
      manualRecoveryStreak: n('manualRecoveryStreak'),
    );
  }
}
