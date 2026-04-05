import 'package:aqarai_app/models/deal_pipeline.dart';

/// Currency and legacy defaults for `deals` documents.
///
/// **Commission** is derived from **final deal price** via [DealCommissionCalculator]
/// (sale: 1%, rent: half of the entered amount for the agreed period).
abstract final class DealsFinancialConfig {
  /// Legacy field on older deal rows; prefer [DealCommissionCalculator].
  static const double defaultCommissionRate = 0.015;

  static const String currency = 'KWD';
}
