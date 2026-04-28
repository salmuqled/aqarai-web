import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'package:aqarai_app/models/listing_enums.dart';

/// Path + query encoding for [PropertyDetailsPage] (SEO / shareable URLs on web).
abstract final class PropertyRoute {
  static const String pathPattern = '/property/:propertyId';

  /// Canonical HTTPS link for sharing (matches [pathPattern], no query params).
  /// Uses [Uri.base.origin] so it works on localhost, staging, or production.
  static String publicShareUrl(String propertyId) {
    final id = propertyId.trim();
    if (id.isEmpty) return Uri.base.origin;
    return '${Uri.base.origin}/property/${Uri.encodeComponent(id)}';
  }

  static String location({
    required String propertyId,
    String leadSource = DealLeadSource.direct,
    String? captionTrackingId,
    String? auctionLotId,
    String? auctionId,
    DateTime? stayStart,
    DateTime? stayEnd,
    String? rentalType,
    bool isAdminView = false,
  }) {
    final qp = <String, String>{};
    final lead = DealLeadSource.normalizeAttributionSource(leadSource);
    if (lead != DealLeadSource.direct) qp['lead'] = lead;
    final cid = captionTrackingId?.trim();
    if (cid != null && cid.isNotEmpty) qp['cid'] = cid;
    final lot = auctionLotId?.trim();
    if (lot != null && lot.isNotEmpty) qp['auctionLot'] = lot;
    final aid = auctionId?.trim();
    if (aid != null && aid.isNotEmpty) qp['auction'] = aid;
    if (stayStart != null) qp['stayStart'] = stayStart.toIso8601String();
    if (stayEnd != null) qp['stayEnd'] = stayEnd.toIso8601String();
    final rt = rentalType?.trim();
    if (rt != null && rt.isNotEmpty) qp['rental'] = rt;
    if (isAdminView) qp['admin'] = '1';

    return Uri(
      path: '/property/$propertyId',
      queryParameters: qp.isEmpty ? null : qp,
    ).toString();
  }
}

extension PropertyDetailsNavigation on BuildContext {
  void pushPropertyDetails({
    required String propertyId,
    String leadSource = DealLeadSource.direct,
    String? captionTrackingId,
    String? auctionLotId,
    String? auctionId,
    DateTime? stayStart,
    DateTime? stayEnd,
    String? rentalType,
    bool isAdminView = false,
  }) {
    push(
      PropertyRoute.location(
        propertyId: propertyId,
        leadSource: leadSource,
        captionTrackingId: captionTrackingId,
        auctionLotId: auctionLotId,
        auctionId: auctionId,
        stayStart: stayStart,
        stayEnd: stayEnd,
        rentalType: rentalType,
        isAdminView: isAdminView,
      ),
    );
  }
}
