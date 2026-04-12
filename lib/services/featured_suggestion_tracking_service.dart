import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;

/// Lightweight Firestore tracking for featured upsell suggestions.
///
/// Events:
/// - suggestion_shown
/// - suggestion_clicked
///
/// Dedupe strategy:
/// - `suggestion_shown` is written at most once per (user, property, day, suggestionType)
/// - `suggestion_clicked` is not deduped (every click is valuable)
abstract final class FeaturedSuggestionTrackingService {
  FeaturedSuggestionTrackingService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  // One id per app process/session (good enough for funnel stitching).
  static final String sessionId = _newSessionId();

  static String _newSessionId() {
    final rng = Random();
    final now = DateTime.now().millisecondsSinceEpoch;
    final r = rng.nextInt(1 << 32);
    return 'sess_${now.toRadixString(16)}_${r.toRadixString(16)}';
  }

  static String deviceType() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return 'other';
    }
  }

  static String _yyyymmdd(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y$m$day';
  }

  static String? _uidOrNull() {
    final u = FirebaseAuth.instance.currentUser;
    final uid = u?.uid.trim();
    return (uid == null || uid.isEmpty) ? null : uid;
  }

  static Map<String, dynamic> _base({
    required String event,
    required String propertyId,
    required String userId,
    required String suggestionType,
    required String source,
    required String experimentId,
    required String variant,
    required String sessionId,
    String? shownEventId,
    String? clickEventId,
    String? paymentId,
  }) {
    final pid = propertyId.trim();
    final uid = userId.trim();
    final st = suggestionType.trim().isEmpty ? 'unknown' : suggestionType.trim();

    return <String, dynamic>{
      'event': event,
      'propertyId': pid,
      'userId': uid,
      'suggestionType': st,
      'timestamp': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(), // legacy-compatible
      'sessionId': sessionId,
      'deviceType': deviceType(),
      'source': source,
      'experimentId': experimentId,
      'variant': variant,
      if (shownEventId != null && shownEventId.trim().isNotEmpty)
        'shownEventId': shownEventId.trim(),
      if (clickEventId != null && clickEventId.trim().isNotEmpty)
        'clickEventId': clickEventId.trim(),
      if (paymentId != null && paymentId.trim().isNotEmpty)
        'paymentId': paymentId.trim(),
    };
  }

  /// Returns the deterministic shown event id (doc id) for stitching.
  static Future<String?> trackShown({
    required String propertyId,
    required String suggestionType,
    required List<String> reasons,
    String source = 'ai_suggestion',
    String experimentId = 'ai_suggestions_v1',
    String variant = 'A',
    String? sessionIdOverride,
  }) async {
    final uid = _uidOrNull();
    if (uid == null || propertyId.trim().isEmpty) return null;

    final day = _yyyymmdd(DateTime.now());
    final pid = propertyId.trim();
    final st = suggestionType.trim().isEmpty ? 'unknown' : suggestionType.trim();
    final docId = 'fs_shown_${uid}_${pid}_${st}_$day';
    final sess = (sessionIdOverride?.trim().isNotEmpty ?? false)
        ? sessionIdOverride!.trim()
        : sessionId;

    try {
      await _db.collection('feature_suggestion_events').doc(docId).set({
        ..._base(
          event: 'suggestion_shown',
          propertyId: pid,
          userId: uid,
          suggestionType: st,
          source: source,
          experimentId: experimentId,
          variant: variant,
          sessionId: sess,
          shownEventId: docId,
        ),
        'reasons': reasons,
        'day': day,
      }, SetOptions(merge: true));
    } catch (_) {
      // Tracking must never break UX.
    }

    return docId;
  }

  /// Returns the created click event doc id (for stitching to conversion).
  static Future<String?> trackClicked({
    required String propertyId,
    required String suggestionType,
    required String shownEventId,
    String source = 'ai_suggestion',
    String experimentId = 'ai_suggestions_v1',
    String variant = 'A',
    String? sessionIdOverride,
  }) async {
    final uid = _uidOrNull();
    if (uid == null || propertyId.trim().isEmpty) return null;

    final pid = propertyId.trim();
    final st = suggestionType.trim().isEmpty ? 'unknown' : suggestionType.trim();
    final sess = (sessionIdOverride?.trim().isNotEmpty ?? false)
        ? sessionIdOverride!.trim()
        : sessionId;

    try {
      final ref = _db.collection('feature_suggestion_events').doc();
      await ref.set({
        ..._base(
          event: 'suggestion_clicked',
          propertyId: pid,
          userId: uid,
          suggestionType: st,
          source: source,
          experimentId: experimentId,
          variant: variant,
          sessionId: sess,
          shownEventId: shownEventId,
          clickEventId: ref.id,
        ),
      });
      return ref.id;
    } catch (_) {
      // ignore
    }
    return null;
  }

  static Future<void> trackConversionSuccess({
    required String propertyId,
    required String suggestionType,
    required String paymentId,
    required int durationDays,
    required double amountKwd,
    required String shownEventId,
    required String clickEventId,
    String source = 'ai_suggestion',
    String experimentId = 'ai_suggestions_v1',
    String variant = 'A',
    String? sessionIdOverride,
  }) async {
    final uid = _uidOrNull();
    if (uid == null || propertyId.trim().isEmpty) return;

    final pid = propertyId.trim();
    final st = suggestionType.trim().isEmpty ? 'unknown' : suggestionType.trim();
    final payId = paymentId.trim();
    if (payId.isEmpty) return;
    final sess = (sessionIdOverride?.trim().isNotEmpty ?? false)
        ? sessionIdOverride!.trim()
        : sessionId;

    // One conversion per payment id.
    final docId = 'fs_conv_$payId';

    try {
      await _db.collection('feature_suggestion_events').doc(docId).set({
        ..._base(
          event: 'ai_conversion_success',
          propertyId: pid,
          userId: uid,
          suggestionType: st,
          source: source,
          experimentId: experimentId,
          variant: variant,
          sessionId: sess,
          shownEventId: shownEventId,
          clickEventId: clickEventId,
          paymentId: payId,
        ),
        'durationDays': durationDays,
        'amountKwd': amountKwd,
      }, SetOptions(merge: true));
    } catch (_) {
      // ignore
    }
  }
}

