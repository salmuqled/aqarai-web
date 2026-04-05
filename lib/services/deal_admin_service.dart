import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/models/deal_pipeline.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/analytics_service.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

double _money(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim()) ?? 0;
}

/// Admin updates to `deals` (final price, commission, pipeline).
class DealAdminService {
  DealAdminService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> dealRef(String dealId) =>
      _db.collection('deals').doc(dealId);

  /// Persists [finalPrice], recalculates commission, applies analytics deltas vs previous values.
  Future<void> saveFinalPriceAndCommission({
    required String dealId,
    required double finalPrice,
  }) async {
    if (finalPrice < 0) {
      throw ArgumentError('finalPrice must be >= 0');
    }

    final ref = dealRef(dealId);

    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) throw StateError('deal_missing');
      final m = snap.data()!;

      final leadSource = _normalizeLeadSource(m);
      final serviceType = DealCommissionCalculator.normalizeServiceType(m);

      final oldFinal = _money(m['finalPrice']);
      final oldComm = getCommission(m);

      final commission =
          DealCommissionCalculator.compute(
            finalPrice: finalPrice,
            serviceType: serviceType,
          );
      final commissionCalculated = finalPrice > 0;

      final dVol = finalPrice - oldFinal;
      final dComm = commission - oldComm;

      tx.update(ref, {
        'finalPrice': finalPrice,
        'commission': commission,
        'commissionAmount': commission,
        'commissionCalculated': commissionCalculated,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if ((dVol != 0 || dComm != 0) && isFinalizedDeal(m)) {
        tx.set(
          AnalyticsService.globalRef(_db),
          AnalyticsService.buildGlobalVolumeCommissionDelta(
            leadSource: leadSource,
            deltaVolumeKwd: dVol,
            deltaCommissionKwd: dComm,
          ),
          SetOptions(merge: true),
        );
      }
    });
  }

  Future<void> saveBookingAmount({
    required String dealId,
    required double bookingAmount,
  }) async {
    if (bookingAmount < 0) throw ArgumentError('bookingAmount must be >= 0');
    await dealRef(dealId).update({
      'bookingAmount': bookingAmount,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setCommissionPaid({
    required String dealId,
    required bool paid,
  }) async {
    final ref = dealRef(dealId);
    final snap = await ref.get();
    if (!snap.exists) throw StateError('deal_missing');
    if (!isFinalizedDeal(snap.data()!)) {
      throw StateError('commission_paid_requires_finalized_deal');
    }
    await ref.update({
      'isCommissionPaid': paid,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  static bool _statusStringIsFinalized(String status) {
    final s = status.trim();
    return s == DealStatus.signed || s == DealStatus.closed;
  }

  /// Moves [dealStatus] pipeline; blocks signed/closed without final price.
  ///
  /// When a deal **first** enters a finalized stage (signed/closed), pushes
  /// current [finalPrice] and [getCommission] to `analytics/global` if they
  /// were never applied while non-finalized (see [saveFinalPriceAndCommission]).
  Future<void> setPipelineStatus({
    required String dealId,
    required String newStatus,
  }) async {
    if (!DealPipelineStatus.ordered.contains(newStatus)) {
      throw ArgumentError('invalid pipeline status');
    }

    final ref = dealRef(dealId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) throw StateError('deal_missing');
      final m = snap.data()!;
      final finalPrice = _money(m['finalPrice']);

      if (DealPipelineStatus.requiresFinalPrice(newStatus) &&
          finalPrice <= 0) {
        throw StateError('final_price_required');
      }

      final wasFinalized = isFinalizedDeal(m);
      final nowFinalized = _statusStringIsFinalized(newStatus);

      final isBooked = newStatus == DealStatus.booked ||
          newStatus == DealStatus.signed ||
          newStatus == DealStatus.closed;
      final isSigned = newStatus == DealStatus.signed ||
          newStatus == DealStatus.closed;

      tx.update(ref, {
        'dealStatus': newStatus,
        'isBooked': isBooked,
        'isSigned': isSigned,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // One-time catch-up: pre-finalized saves do not touch analytics/global.
      if (!wasFinalized && nowFinalized) {
        final vol = _money(m['finalPrice']);
        final comm = getCommission(m);
        if (vol != 0 || comm != 0) {
          final leadSource = _normalizeLeadSource(m);
          tx.set(
            AnalyticsService.globalRef(_db),
            AnalyticsService.buildGlobalVolumeCommissionDelta(
              leadSource: leadSource,
              deltaVolumeKwd: vol,
              deltaCommissionKwd: comm,
            ),
            SetOptions(merge: true),
          );
        }
      }
    });
  }

  static String _normalizeLeadSource(Map<String, dynamic> m) {
    final raw = m['leadSource']?.toString().trim();
    if (raw == null || raw.isEmpty) return DealLeadSource.unknown;
    if (raw == DealLeadSource.interestedButton) {
      return DealLeadSource.interestedButton;
    }
    if (DealLeadSource.isAttributionSource(raw)) return raw;
    return DealLeadSource.unknown;
  }
}
