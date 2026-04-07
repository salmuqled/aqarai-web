import 'package:flutter/material.dart';

import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';

/// Localized [dealStatus] for admin lists; Firestore values stay unchanged.
String getDealStatusLabel(BuildContext context, String status) {
  final loc = AppLocalizations.of(context);
  if (loc == null) return status;
  final s = status.trim();
  switch (s) {
    case DealStatus.newLead:
      return loc.adminDealPipelineNewLeads;
    case DealStatus.contacted:
      return loc.adminDealPipelineContacted;
    case DealStatus.qualified:
      return loc.adminDealPipelineQualified;
    case DealStatus.booked:
      return loc.adminDealPipelineBooked;
    case DealStatus.signed:
      return loc.adminDealPipelineSigned;
    case DealStatus.closed:
      return loc.adminDealPipelineClosed;
    case DealStatus.notInterested:
      return loc.adminDealPipelineNotInterested;
    default:
      return status;
  }
}
