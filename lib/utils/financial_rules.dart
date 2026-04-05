import 'package:aqarai_app/constants/deal_constants.dart';

/// Single source of truth for deal financial interpretation (`deals` documents).

/// CRM finalized stages only — uses `dealStatus`, not legacy `status`.
bool isFinalizedDeal(Map<String, dynamic> m) {
  final s = (m['dealStatus'] ?? '').toString().trim();
  return s == DealStatus.signed || s == DealStatus.closed;
}

/// Prefer `commission`, then `commissionAmount`; tolerates string numerics for legacy data.
double getCommission(Map<String, dynamic> m) {
  final c = m['commission'];
  final ca = m['commissionAmount'];
  if (c is num) return c.toDouble();
  if (c != null) {
    final p = double.tryParse(c.toString().trim());
    if (p != null) return p;
  }
  if (ca is num) return ca.toDouble();
  if (ca != null) {
    final p = double.tryParse(ca.toString().trim());
    if (p != null) return p;
  }
  return 0;
}

/// Service mix: `rent` vs `sale` (includes exchange); `null` = other / uncategorized.
String? getServiceBucket(Map<String, dynamic> m) {
  final t = (m['serviceType'] ?? m['dealType'] ?? m['requestType'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
  if (t == 'rent') return 'rent';
  if (t == 'sale' || t == 'exchange') return 'sale';
  return null;
}

bool isPaid(Map<String, dynamic> m) {
  return m['isCommissionPaid'] == true;
}
