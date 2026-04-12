import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Firestore `upload_events` — property image pipeline telemetry.
abstract final class PropertyImageUploadEventType {
  static const String imageUploadStarted = 'image_upload_started';
  static const String imageUploadFailed = 'image_upload_failed';
  static const String imageUploadRetry = 'image_upload_retry';
  static const String imageUploadSuccess = 'image_upload_success';
}

abstract final class UploadEventsService {
  UploadEventsService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Append-only log for dashboard / reliability metrics.
  static Future<void> logPropertyImageUpload({
    required String eventType,
    required String propertyId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      debugPrint('[UploadEvents] skip (no user): $eventType $propertyId');
      return;
    }
    try {
      await _db.collection('upload_events').add({
        'propertyId': propertyId,
        'userId': uid,
        'eventType': eventType,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[UploadEvents] write failed: $e');
    }
  }
}
