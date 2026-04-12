import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/models/deal_pipeline.dart';
import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/analytics_service.dart';
import 'package:aqarai_app/services/deal_follow_up_local_notifications.dart';
import 'package:aqarai_app/utils/financial_rules.dart';

double _money(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().trim()) ?? 0;
}

/// Called only when `deals.dealStatus` becomes [DealStatus.closed] — sets terminal
/// `properties.status` + `dealStatus: closed` + `sold` (sale only). Invalid terminal
/// rows without closed deals are corrected by [onPropertyTerminalStatusGuard] (CF).
void _syncPropertyWhenDealCloses(
  Transaction tx,
  FirebaseFirestore db,
  Map<String, dynamic> deal,
) {
  final propertyId = deal['propertyId']?.toString().trim() ?? '';
  if (propertyId.isEmpty) return;

  final rawType =
      (deal['dealType'] ?? CloseRequestType.sale).toString().trim();
  final requestType = rawType == CloseRequestType.rent
      ? CloseRequestType.rent
      : rawType == CloseRequestType.exchange
          ? CloseRequestType.exchange
          : CloseRequestType.sale;

  final terminal = finalStatusForRequestType(requestType);
  final soldFlag = requestType == CloseRequestType.sale;

  tx.update(db.collection('properties').doc(propertyId), {
    'status': terminal,
    'dealStatus': DealStatus.closed,
    'sold': soldFlag,
    'updatedAt': FieldValue.serverTimestamp(),
  });
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

  /// Commission "paid" is derived from confirmed `company_payments` (Cloud Function mirrors).
  @Deprecated('Use company_payments ledger; server updates isCommissionPaid.')
  Future<void> setCommissionPaid({
    required String dealId,
    required bool paid,
  }) async {
    throw UnsupportedError(
      'setCommissionPaid is disabled: confirm a commission row in company_payments.',
    );
  }

  /// Close the deal after commission is reflected in the ledger (or no commission due).
  Future<void> markCommissionReceivedAndClose({required String dealId}) async {
    final ref = dealRef(dealId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) throw StateError('deal_missing');
      final m = snap.data()!;
      final st = (m['dealStatus'] ?? '').toString().trim();
      if (st != DealStatus.signed && st != DealStatus.closed) {
        throw StateError('commission_collect_invalid_status');
      }
      final due = getCommission(m);
      if (due > 0 && !isPaid(m)) {
        throw StateError('commission_not_confirmed_in_ledger');
      }
      final prevSt = st;
      final patch = <String, dynamic>{
        'dealStatus': DealStatus.closed,
        'isBooked': true,
        'isSigned': true,
        'lastContactAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (prevSt != DealStatus.closed) {
        patch['closedAt'] = FieldValue.serverTimestamp();
      } else if (m['closedAt'] == null) {
        patch['closedAt'] = FieldValue.serverTimestamp();
      }
      tx.update(ref, patch);
      _syncPropertyWhenDealCloses(tx, _db, {...m, ...patch});
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

      final prevStatus = (m['dealStatus'] ?? '').toString().trim();
      final patch = <String, dynamic>{
        'dealStatus': newStatus,
        'isBooked': isBooked,
        'isSigned': isSigned,
        'lastContactAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      if (newStatus == DealStatus.closed && prevStatus != DealStatus.closed) {
        patch['closedAt'] = FieldValue.serverTimestamp();
      }

      tx.update(ref, patch);

      if (newStatus == DealStatus.closed) {
        _syncPropertyWhenDealCloses(tx, _db, {...m, ...patch});
      }

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

  static const int _maxNoteLength = 4000;

  /// Appends one note `{ text, createdAt }` to [notes] (Firestore arrayUnion).
  Future<void> appendDealNote({
    required String dealId,
    required String text,
  }) async {
    final t = text.trim();
    if (t.isEmpty) throw ArgumentError('note text empty');
    if (t.length > _maxNoteLength) {
      throw ArgumentError('note too long');
    }
    await dealRef(dealId).update({
      'notes': FieldValue.arrayUnion([
        {
          'text': t,
          'createdAt': Timestamp.fromDate(DateTime.now().toUtc()),
        },
      ]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Sets [nextFollowUpAt] for CRM reminders (server stores UTC instant).
  Future<void> setNextFollowUpAt({
    required String dealId,
    required DateTime at,
  }) async {
    await dealRef(dealId).update({
      'nextFollowUpAt': Timestamp.fromDate(at.toUtc()),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await DealFollowUpLocalNotifications.rescheduleAfterFollowUpSave(
      dealId: dealId,
      at: at,
    );
  }

  /// Clears scheduled follow-up (e.g. after closing the loop).
  Future<void> clearNextFollowUpAt({required String dealId}) async {
    await dealRef(dealId).update({
      'nextFollowUpAt': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await DealFollowUpLocalNotifications.cancelForDeal(dealId);
  }

  /// Marks that contact happened now (pipeline may stay unchanged).
  Future<void> markLastContactNow({required String dealId}) async {
    await dealRef(dealId).update({
      'lastContactAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
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
