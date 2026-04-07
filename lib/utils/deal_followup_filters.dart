import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/constants/deal_constants.dart';

/// Excluded from the follow-up dashboard (terminal / dropped).
bool dealStatusExcludedFromFollowUpDashboard(String status) {
  final s = status.trim();
  return s == DealStatus.closed || s == DealStatus.notInterested;
}

/// [nextFollowUpAt] is set and not in the future; status allows follow-up work.
bool isDealFollowUpDueNow(Map<String, dynamic> data) {
  if (dealStatusExcludedFromFollowUpDashboard(
        data['dealStatus']?.toString() ?? '',
      )) {
    return false;
  }
  final n = data['nextFollowUpAt'];
  if (n is! Timestamp) return false;
  return n.compareTo(Timestamp.now()) <= 0;
}
