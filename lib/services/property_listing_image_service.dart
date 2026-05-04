import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'package:aqarai_app/models/listing_enums.dart';
import 'package:aqarai_app/services/image_processing_service.dart';
import 'package:aqarai_app/services/upload_events_service.dart';

/// Uploads listing photos to `users/{uid}/property_images/{propertyId}/…` (full + thumbnail per slot)
/// and sets [hasImage] + [status] to [ListingStatus.active].
abstract final class PropertyListingImageService {
  PropertyListingImageService._();

  static const int maxImageBytes = 12 * 1024 * 1024;
  static const int maxAttempts = 3;

  static void _logAttempt(int attempt, Object error, StackTrace? stack) {
    if (error is FirebaseException) {
      debugPrint(
        '[PropertyListingImage] FirebaseException attempt=$attempt '
        'code=${error.code} message=${error.message} plugin=${error.plugin}',
      );
    } else {
      debugPrint('[PropertyListingImage] attempt=$attempt error=$error');
    }
    if (stack != null && kDebugMode) debugPrint('$stack');
  }

  static Future<void> _putFileWithRetry({
    required Reference ref,
    required File file,
  }) async {
    Object? lastErr;
    StackTrace? lastSt;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await ref.putFile(
          file,
          SettableMetadata(
            contentType: 'image/jpeg',
            cacheControl: 'public, max-age=31536000',
          ),
        );
        debugPrint(
          '[PropertyListingImage] OK path=${ref.fullPath} attempt=$attempt',
        );
        return;
      } on FirebaseException catch (e, st) {
        lastErr = e;
        lastSt = st;
        _logAttempt(attempt, e, st);
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
        }
      } catch (e, st) {
        lastErr = e;
        lastSt = st;
        _logAttempt(attempt, e, st);
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
        }
      }
    }
    Error.throwWithStackTrace(
      lastErr ?? StateError('Upload failed after $maxAttempts attempts'),
      lastSt ?? StackTrace.empty,
    );
  }

  static Future<void> _validateFileAsync(File file) async {
    if (!await file.exists()) {
      throw StateError('Image missing at ${file.path}');
    }
    final len = await file.length();
    if (len <= 0) throw StateError('Image file is empty');
    if (len > maxImageBytes) {
      throw StateError('Image exceeds ${maxImageBytes ~/ (1024 * 1024)}MB');
    }
  }

  /// Puts full + thumbnail in Storage. Does not write Firestore.
  ///
  /// When [isUserRetry] is true (e.g. My Ads → Retry upload), logs retry then started.
  static Future<UploadedListingPhoto> uploadMainPhotoToStorage({
    required String propertyId,
    required File file,
    bool isUserRetry = false,
  }) async {
    final thumb = await ImageProcessingService.createThumbnailFrom(file);
    try {
      final list = await uploadListingPhotosToStorage(
        propertyId: propertyId,
        photos: [ProcessedListingPhoto(full: file, thumbnail: thumb)],
        isUserRetry: isUserRetry,
      );
      return list.single;
    } finally {
      await ImageProcessingService.tryDeleteTemp(thumb);
    }
  }

  /// Uploads one or more (full, thumbnail) pairs; rolls back Storage on failure.
  static Future<List<UploadedListingPhoto>> uploadListingPhotosToStorage({
    required String propertyId,
    required List<ProcessedListingPhoto> photos,
    bool isUserRetry = false,
  }) async {
    if (photos.isEmpty) {
      throw ArgumentError.value(photos, 'photos', 'must not be empty');
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('Sign in required to upload listing photos');
    }
    await FirebaseAuth.instance.currentUser?.getIdToken(true);

    for (final p in photos) {
      await _validateFileAsync(p.full);
      await _validateFileAsync(p.thumbnail);
    }

    if (isUserRetry) {
      await UploadEventsService.logPropertyImageUpload(
        eventType: PropertyImageUploadEventType.imageUploadRetry,
        propertyId: propertyId,
      );
    }
    await UploadEventsService.logPropertyImageUpload(
      eventType: PropertyImageUploadEventType.imageUploadStarted,
      propertyId: propertyId,
    );

    final uploaded = <Reference>[];
    final baseMs = DateTime.now().millisecondsSinceEpoch;

    try {
      final out = <UploadedListingPhoto>[];
      for (var i = 0; i < photos.length; i++) {
        final p = photos[i];
        final fullRef = FirebaseStorage.instance.ref().child(
          'users/$uid/property_images/$propertyId/$baseMs''_$i.jpg',
        );
        final thumbRef = FirebaseStorage.instance.ref().child(
          'users/$uid/property_images/$propertyId/$baseMs''_${i}_t.jpg',
        );

        await _putFileWithRetry(ref: fullRef, file: p.full);
        uploaded.add(fullRef);
        await _putFileWithRetry(ref: thumbRef, file: p.thumbnail);
        uploaded.add(thumbRef);

        final fullUrl = await fullRef.getDownloadURL();
        final thumbUrl = await thumbRef.getDownloadURL();
        out.add(
          UploadedListingPhoto(
            fullUrl: fullUrl,
            thumbUrl: thumbUrl,
            fullRef: fullRef,
            thumbRef: thumbRef,
          ),
        );
      }
      return out;
    } catch (e, st) {
      debugPrint('[PropertyListingImage] batch upload failed: $e\n$st');
      for (final ref in uploaded) {
        try {
          await ref.delete();
        } catch (e, st) {
          debugPrint(
            '[PropertyListingImage] cleanup Storage ref after batch failure: $e\n$st',
          );
        }
      }
      await UploadEventsService.logPropertyImageUpload(
        eventType: PropertyImageUploadEventType.imageUploadFailed,
        propertyId: propertyId,
      );
      rethrow;
    }
  }

  /// After successful Storage upload, activate the listing for moderation / browse rules.
  static Future<void> applyUploadedImageToProperty({
    required String propertyId,
    required String downloadUrl,
    required String thumbnailUrl,
    bool setDocumentIdField = true,
  }) async {
    await applyUploadedImagesToProperty(
      propertyId: propertyId,
      fullUrls: [downloadUrl],
      thumbnailUrls: [thumbnailUrl],
      setDocumentIdField: setDocumentIdField,
    );
  }

  static Future<void> applyUploadedImagesToProperty({
    required String propertyId,
    required List<String> fullUrls,
    required List<String> thumbnailUrls,
    bool setDocumentIdField = true,
  }) async {
    if (fullUrls.isEmpty) {
      throw ArgumentError.value(fullUrls, 'fullUrls', 'must not be empty');
    }
    if (thumbnailUrls.length != fullUrls.length) {
      throw ArgumentError(
        'thumbnailUrls.length (${thumbnailUrls.length}) must equal '
        'fullUrls.length (${fullUrls.length})',
      );
    }

    final doc =
        FirebaseFirestore.instance.collection('properties').doc(propertyId);
    final payload = <String, dynamic>{
      'images': fullUrls,
      'thumbnails': thumbnailUrls,
      'hasImage': true,
      'status': ListingStatus.active,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (setDocumentIdField) {
      payload['id'] = propertyId;
    }
    try {
      if (kDebugMode) {
        debugPrint(
          '[PropertyListingImage] applyUploadedImages propertyId=$propertyId '
          'status=${ListingStatus.active} hasImage=true '
          'images=${fullUrls.length} thumbnails=${thumbnailUrls.length}',
        );
      }
      await doc.update(payload);
      await UploadEventsService.logPropertyImageUpload(
        eventType: PropertyImageUploadEventType.imageUploadSuccess,
        propertyId: propertyId,
      );
    } catch (e) {
      await UploadEventsService.logPropertyImageUpload(
        eventType: PropertyImageUploadEventType.imageUploadFailed,
        propertyId: propertyId,
      );
      rethrow;
    }
  }
}

class UploadedListingPhoto {
  const UploadedListingPhoto({
    required this.fullUrl,
    required this.thumbUrl,
    required this.fullRef,
    required this.thumbRef,
  });

  final String fullUrl;
  final String thumbUrl;
  final Reference fullRef;
  final Reference thumbRef;
}
