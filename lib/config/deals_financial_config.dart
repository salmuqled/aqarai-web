/// Defaults for deal financial fields (commission). Tune per business policy.
abstract final class DealsFinancialConfig {
  /// Default commission rate when admin does not pass one (e.g. 1.5%).
  static const double defaultCommissionRate = 0.015;

  static const String currency = 'KWD';
}
