import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:aqarai_app/config/deals_financial_config.dart';
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/analytics_service.dart';
import 'package:aqarai_app/services/lead_source_attribution.dart';

num? _parseNum(dynamic v) {
  if (v == null) return null;
  if (v is num) return v;
  return num.tryParse(v.toString().trim());
}

/// Owner closure requests + admin approve/reject + `deals` record.
class PropertyClosureService {
  PropertyClosureService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const int _kNotificationConversionMaxHours = 48;

  /// إن كان مالك الإعلان نقر مؤخراً على إشعار (ضمن النافذة) نربط الصفقة بـ [sourceNotificationId].
  Future<String?> _sourceNotificationIdForOwner(String ownerId) async {
    if (ownerId.isEmpty) return null;
    try {
      final doc = await _db.collection('users').doc(ownerId).get();
      final data = doc.data();
      if (data == null) return null;
      final nid = data['lastClickedNotificationId']?.toString().trim();
      if (nid == null || nid.isEmpty) return null;
      final ts = data['lastClickedNotificationAt'];
      if (ts is! Timestamp) return null;
      final hours = DateTime.now().difference(ts.toDate()).inHours;
      if (hours < 0 || hours > _kNotificationConversionMaxHours) return null;
      return nid.length > 200 ? nid.substring(0, 200) : nid;
    } catch (_) {
      return null;
    }
  }

  /// Loads up to 50 recent views for [propertyId] (all users) and resolves lead source.
  Future<String> _resolveLeadSourceFromRecentViews(String propertyId) async {
    try {
      final snap = await _db
          .collection('property_views')
          .where('propertyId', isEqualTo: propertyId)
          .orderBy('viewedAt', descending: true)
          .limit(50)
          .get();
      return LeadSourceAttribution.resolveLeadSource(snap.docs);
    } catch (_) {
      return DealLeadSource.unknown;
    }
  }

  /// Owner: hide from public immediately, create `closure_requests` row.
  Future<String> submitClosureRequest({
    required String propertyId,
    required String requestType,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      throw StateError('not_signed_in');
    }

    // Attribution: weighted blend of recent views on this listing (any viewer).
    final leadSource = await _resolveLeadSourceFromRecentViews(propertyId);

    final propRef = _db.collection('properties').doc(propertyId);
    return _db.runTransaction<String>((tx) async {
      final snap = await tx.get(propRef);
      if (!snap.exists) throw StateError('property_missing');
      final d = snap.data()!;
      if (d['ownerId']?.toString() != uid) throw StateError('not_owner');
      if (listingDataIsChalet(d)) throw StateError('chalet_use_bookings');
      if (d['approved'] != true) throw StateError('not_approved');
      if (d['closeRequestSubmitted'] == true) {
        throw StateError('already_submitted');
      }

      final st = (d['status'] ?? ListingStatus.active).toString().trim();
      if (st != ListingStatus.active && st != ListingStatus.approvedLegacy) {
        throw StateError('invalid_status');
      }

      final pendingStatus = pendingStatusForRequestType(requestType);
      final reqRef = _db.collection('closure_requests').doc();
      final title = listingDisplayTitleFromProperty(d);

      tx.set(reqRef, {
        'propertyId': propertyId,
        'ownerId': uid,
        'listingCategory': d['listingCategory'] ?? ListingCategory.normal,
        'propertyType': d['type'] ?? '',
        'serviceType': d['serviceType'] ?? '',
        'requestType': requestType,
        'listingPrice': d['price'],
        'governorateAr': d['governorateAr'] ?? d['governorate'] ?? '',
        'areaAr': d['areaAr'] ?? d['area'] ?? '',
        'governorateEn': d['governorateEn'] ?? '',
        'areaEn': d['areaEn'] ?? '',
        'title': title,
        'ownerPhone': d['ownerPhone'] ?? '',
        'leadSource': leadSource,
        'requestedAt': FieldValue.serverTimestamp(),
        'status': ClosureRequestStatus.pending,
        'adminNote': null,
        'reviewedAt': null,
        'reviewedBy': null,
      });

      tx.update(propRef, {
        'hiddenFromPublic': true,
        'status': pendingStatus,
        'closeRequestSubmitted': true,
        'closeRequestType': requestType,
        'closeRequestedAt': FieldValue.serverTimestamp(),
        'closeRequestedBy': uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      return reqRef.id;
    });
  }

  /// Admin: finalize sale/rent/exchange → `deals` + property terminal status.
  ///
  /// Creates a deal with **finalPrice = 0**; admin must set the agreed price in
  /// [AdminDealDetailPage] so commission is based on the real deal price.
  Future<String> approveClosureRequest({
    required String requestId,
    required String adminUid,
    String? adminNote,
    String leadSource = DealLeadSource.unknown,
    String? buyerId,
  }) async {
    final reqRef = _db.collection('closure_requests').doc(requestId);
    final snap = await reqRef.get();
    if (!snap.exists) throw StateError('request_missing');
    final r = snap.data()!;
    if (r['status'] != ClosureRequestStatus.pending) {
      throw StateError('not_pending');
    }

    final propertyId = r['propertyId']?.toString() ?? '';
    if (propertyId.isEmpty) throw StateError('bad_request');

    final propRef = _db.collection('properties').doc(propertyId);
    final propSnap = await propRef.get();
    if (!propSnap.exists) throw StateError('property_missing');
    final p = propSnap.data()!;

    final requestType = r['requestType']?.toString() ?? CloseRequestType.sale;
    final finalStatus = finalStatusForRequestType(requestType);

    // --- Financials: require listing price from request or property; final price falls back to listing.
    final listingPriceRaw = r['listingPrice'] ?? p['price'];
    final listingPriceNum = _parseNum(listingPriceRaw);
    if (listingPriceNum == null) {
      throw StateError('listing_price_required');
    }

    // Final price & commission are entered later on the deal (brokerage accuracy).
    final serviceTypeForDeal =
        requestType == CloseRequestType.rent ? 'rent' : 'sale';

    // Copy from closure request when present (new pipeline); else admin-supplied param (legacy / override).
    final fromRequest = r['leadSource']?.toString().trim();
    final dealLeadSource = (fromRequest != null && fromRequest.isNotEmpty)
        ? fromRequest
        : leadSource;

    final dealRef = _db.collection('deals').doc();
    final batch = _db.batch();

    final ownerIdForNotif =
        (p['ownerId'] ?? r['ownerId'])?.toString().trim() ?? '';
    final sourceNotificationId =
        await _sourceNotificationIdForOwner(ownerIdForNotif);

    batch.update(reqRef, {
      'status': ClosureRequestStatus.approved,
      'adminNote': adminNote,
      'reviewedAt': FieldValue.serverTimestamp(),
      'reviewedBy': adminUid,
      'dealId': dealRef.id,
    });

    batch.update(propRef, {
      'status': finalStatus,
      'hiddenFromPublic': true,
      'closeApprovedAt': FieldValue.serverTimestamp(),
      'closeApprovedBy': adminUid,
      'closeRequestSubmitted': true,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    final dealTitle = r['title'] ?? listingDisplayTitleFromProperty(p);

    final dealPayload = <String, dynamic>{
      'status': 'sold',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'propertyId': propertyId,
      'propertyTitle': dealTitle,
      'propertyPrice': listingPriceNum,
      'ownerId': p['ownerId'] ?? r['ownerId'],
      'buyerId': buyerId,
      'dealType': requestType,
      'serviceType': serviceTypeForDeal,
      'propertyType': p['type'] ?? r['propertyType'],
      'listingCategory': p['listingCategory'] ?? ListingCategory.normal,
      'governorateAr': p['governorateAr'] ?? r['governorateAr'] ?? '',
      'areaAr': p['areaAr'] ?? r['areaAr'] ?? '',
      'governorateEn': p['governorateEn'] ?? r['governorateEn'] ?? '',
      'areaEn': p['areaEn'] ?? r['areaEn'] ?? '',
      'title': dealTitle,
      'listingPrice': listingPriceNum,
      'finalPrice': 0.0,
      'commission': 0.0,
      'commissionAmount': 0.0,
      'commissionCalculated': false,
      'commissionRate': 0.0,
      'bookingAmount': 0.0,
      'dealStatus': DealStatus.booked,
      'isBooked': true,
      'isSigned': false,
      'isCommissionPaid': false,
      'currency': DealsFinancialConfig.currency,
      'leadSource': dealLeadSource,
      'closedAt': FieldValue.serverTimestamp(),
      'closedBy': adminUid,
      'closureRequestId': requestId,
      'notes': adminNote,
    };
    if (sourceNotificationId != null) {
      dealPayload['sourceNotificationId'] = sourceNotificationId;
    }
    batch.set(dealRef, dealPayload);

    // Count the deal now; volume & commission increment when admin sets finalPrice.
    batch.set(
      AnalyticsService.globalRef(_db),
      AnalyticsService.buildGlobalIncrementPayload(
        leadSource: dealLeadSource,
        volumeKwd: 0,
        commissionKwd: 0,
      ),
      SetOptions(merge: true),
    );

    await batch.commit();
    return dealRef.id;
  }

  /// Admin: restore listing to public active feed.
  Future<void> rejectClosureRequest({
    required String requestId,
    required String adminUid,
    String? adminNote,
  }) async {
    final reqRef = _db.collection('closure_requests').doc(requestId);
    final snap = await reqRef.get();
    if (!snap.exists) throw StateError('request_missing');
    final r = snap.data()!;
    if (r['status'] != ClosureRequestStatus.pending) {
      throw StateError('not_pending');
    }

    final propertyId = r['propertyId']?.toString() ?? '';
    final propRef = _db.collection('properties').doc(propertyId);

    final batch = _db.batch();
    batch.update(reqRef, {
      'status': ClosureRequestStatus.rejected,
      'adminNote': adminNote,
      'reviewedAt': FieldValue.serverTimestamp(),
      'reviewedBy': adminUid,
    });

    batch.update(propRef, {
      'hiddenFromPublic': false,
      'status': ListingStatus.active,
      'closeRequestSubmitted': false,
      'closeRequestType': FieldValue.delete(),
      'closeRequestedAt': FieldValue.delete(),
      'closeRequestedBy': FieldValue.delete(),
      'closeApprovedAt': FieldValue.delete(),
      'closeApprovedBy': FieldValue.delete(),
      'closeRejectedAt': FieldValue.serverTimestamp(),
      'closeRejectedBy': adminUid,
      'closeRejectReason': adminNote,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }
}
