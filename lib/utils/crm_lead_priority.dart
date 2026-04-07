import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/constants/deal_constants.dart';

/// Derived CRM priority for `deals` (no extra Firestore fields).
enum CrmLeadPriority {
  urgent,
  high,
  medium,
  low;

  /// Lower sorts first (more important).
  int get sortKey => switch (this) {
    CrmLeadPriority.urgent => 0,
    CrmLeadPriority.high => 1,
    CrmLeadPriority.medium => 2,
    CrmLeadPriority.low => 3,
  };
}

bool crmDealStatusIsTerminal(String st) {
  final s = st.trim();
  return s == DealStatus.closed || s == DealStatus.notInterested;
}

/// [nextFollowUpAt] is in the past and the deal is still actionable.
bool crmIsFollowUpOverdue(Map<String, dynamic> d, DateTime now) {
  final st = (d['dealStatus'] ?? d['status'] ?? '').toString().trim();
  if (crmDealStatusIsTerminal(st)) return false;
  final nf = d['nextFollowUpAt'];
  if (nf is! Timestamp) return false;
  return nf.toDate().isBefore(now);
}

/// Priority rules: overdue follow-up → urgent; new & negotiating → high;
/// contacted → medium; terminal → low.
CrmLeadPriority crmComputeLeadPriority(Map<String, dynamic> d, DateTime now) {
  if (crmIsFollowUpOverdue(d, now)) return CrmLeadPriority.urgent;

  final st = (d['dealStatus'] ?? d['status'] ?? '').toString().trim();
  if (crmDealStatusIsTerminal(st)) return CrmLeadPriority.low;

  if (st.isEmpty || st == DealStatus.newLead) return CrmLeadPriority.high;
  if (st == DealStatus.contacted) return CrmLeadPriority.medium;
  if (st == DealStatus.qualified ||
      st == DealStatus.booked ||
      st == DealStatus.signed) {
    return CrmLeadPriority.high;
  }
  return CrmLeadPriority.medium;
}
