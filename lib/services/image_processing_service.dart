import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

/// Full-size listing photo + thumbnail (JPEG) before Storage upload.
class ProcessedListingPhoto {
  const ProcessedListingPhoto({required this.full, required this.thumbnail});

  final File full;
  final File thumbnail;
}

/// Smart resize / JPEG conversion / compression before Storage upload.
///
/// Heavy work uses the platform channel (not [compute]); we process sequentially
/// and yield to the UI between items ([processListingPhotosWithProgress]).
abstract final class ImageProcessingService {
  ImageProcessingService._();

  static const int maxImages = 10;
  static const int maxDimensionPx = 1600;
  static const int maxBytesUploadAsIs = 700 * 1024;
  static const int jpegQuality = 77;
  static const int jpegQualitySecondPass = 65;
  static const int jpegQualityThirdPass = 55;

  /// Target max size after compression passes (second pass applies if exceeded).
  static const int maxBytesAfterCompression = 500 * 1024;

  static const int thumbnailMaxDimensionPx = 300;
  /// Slightly higher than 60 for clearer list thumbnails without large files.
  static const int thumbnailJpegQuality = 68;

  static const String _tempFullPrefix = 'aqarai_proc_';
  static const String _tempThumbPrefix = 'aqarai_proc_thumb_';

  static bool isProcessedTempFile(File file) {
    final p = file.path;
    return p.contains(_tempFullPrefix) || p.contains(_tempThumbPrefix);
  }

  /// Gallery multi-pick. Respects [maxSelectable] (cap after pick).
  static Future<ImagePickResult?> pickImages({int? maxSelectable}) async {
    final cap = (maxSelectable ?? maxImages).clamp(1, maxImages);
    final picker = ImagePicker();
    final xFiles = await picker.pickMultiImage(imageQuality: 100);
    if (xFiles.isEmpty) return null;

    var truncated = false;
    var use = xFiles;
    if (xFiles.length > cap) {
      truncated = true;
      use = xFiles.sublist(0, cap);
    }

    return ImagePickResult(
      files: use.map((x) => File(x.path)).toList(),
      truncatedFromSelection: truncated,
    );
  }

  /// As-is only when: JPEG/JPG, size ≤ 700KB, max(width,height) ≤ 1600px.
  static Future<File> processImage(File file) async {
    if (!await file.exists()) {
      throw StateError('Image missing at ${file.path}');
    }
    final len = await file.length();
    if (len <= 0) throw StateError('Image file is empty');

    final lower = file.path.toLowerCase();
    final looksJpeg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');

    if (looksJpeg && len <= maxBytesUploadAsIs) {
      final dims = await _readDimensions(file);
      if (dims != null) {
        final maxSide = math.max(dims.width, dims.height);
        if (maxSide <= maxDimensionPx) {
          return file;
        }
      }
    }

    return compressImage(file);
  }

  /// At most two compression passes (77 then 65 if still > [maxBytesAfterCompression]).
  static Future<File> compressImage(File file) async {
    var current = await _compressToTemp(file, jpegQuality);
    if (await current.length() <= maxBytesAfterCompression) {
      return current;
    }
    final second = await _compressToTemp(current, jpegQualitySecondPass);
    await tryDeleteTemp(current);
    return second;
  }

  static Future<File> _compressToTemp(File source, int quality) async {
    final dir = Directory.systemTemp.path;
    final targetPath =
        '$dir/$_tempFullPrefix${DateTime.now().microsecondsSinceEpoch}_${source.hashCode.abs()}.jpg';

    final out = await FlutterImageCompress.compressAndGetFile(
      source.absolute.path,
      targetPath,
      quality: quality,
      format: CompressFormat.jpeg,
      minWidth: maxDimensionPx,
      minHeight: maxDimensionPx,
    );

    if (out == null) {
      throw StateError('Image compression failed');
    }
    final result = File(out.path);
    if (!await result.exists() || await result.length() <= 0) {
      throw StateError('Compressed image is empty');
    }
    return result;
  }

  /// As-is originals (not our temp) may still be >500KB; max two extra passes.
  static Future<File> _shrinkNonTempFullIfOversized(File full) async {
    if (await full.length() <= maxBytesAfterCompression) return full;
    if (isProcessedTempFile(full)) {
      return full;
    }

    var current = full;
    for (var pass = 0;
        pass < 2 && await current.length() > maxBytesAfterCompression;
        pass++) {
      final q = pass == 0 ? jpegQualitySecondPass : jpegQualityThirdPass;
      final next = await _compressToTemp(current, q);
      if (isProcessedTempFile(current)) await tryDeleteTemp(current);
      current = next;
    }
    return current;
  }

  /// Thumbnail: max edge [thumbnailMaxDimensionPx], JPEG [thumbnailJpegQuality].
  static Future<File> createThumbnailFrom(File sourceFull) async {
    if (!await sourceFull.exists()) {
      throw StateError('Image missing at ${sourceFull.path}');
    }
    final dir = Directory.systemTemp.path;
    final targetPath =
        '$dir/$_tempThumbPrefix${DateTime.now().microsecondsSinceEpoch}_${sourceFull.hashCode.abs()}.jpg';

    final out = await FlutterImageCompress.compressAndGetFile(
      sourceFull.absolute.path,
      targetPath,
      quality: thumbnailJpegQuality,
      format: CompressFormat.jpeg,
      minWidth: thumbnailMaxDimensionPx,
      minHeight: thumbnailMaxDimensionPx,
    );

    if (out == null) {
      throw StateError('Thumbnail compression failed');
    }
    final result = File(out.path);
    if (!await result.exists() || await result.length() <= 0) {
      throw StateError('Thumbnail file is empty');
    }
    return result;
  }

  /// Full pipeline: [processImage] → optional shrink for non-temp oversize → thumbnail.
  static Future<ProcessedListingPhoto> processListingPhoto(File raw) async {
    final full = await _shrinkNonTempFullIfOversized(await processImage(raw));
    final thumbnail = await createThumbnailFrom(full);
    return ProcessedListingPhoto(full: full, thumbnail: thumbnail);
  }

  static Future<List<ProcessedListingPhoto>> processListingPhotos(
    List<File> files,
  ) async {
    final out = <ProcessedListingPhoto>[];
    for (final f in files) {
      out.add(await processListingPhoto(f));
    }
    return out;
  }

  /// Sequential processing with UI-friendly progress ([completed] in 0..[total]).
  static Future<List<ProcessedListingPhoto>> processListingPhotosWithProgress(
    List<File> files, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final out = <ProcessedListingPhoto>[];
    final total = files.length;
    onProgress?.call(0, total);
    for (var i = 0; i < files.length; i++) {
      await Future<void>.delayed(Duration.zero);
      out.add(await processListingPhoto(files[i]));
      onProgress?.call(i + 1, total);
    }
    return out;
  }

  static Future<List<File>> processImages(List<File> files) async {
    final out = <File>[];
    for (final f in files) {
      out.add(await processImage(f));
    }
    return out;
  }

  static Future<({int width, int height})?> _readDimensions(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      return (width: w, height: h);
    } catch (_) {
      return null;
    }
  }

  static Future<void> tryDeleteTemp(File file) async {
    try {
      if (await file.exists() && isProcessedTempFile(file)) {
        await file.delete();
      }
    } catch (e, st) {
      debugPrint('Error in ImageProcessingService.tryDeleteTemp: $e\n$st');
    }
  }

  static Future<void> tryDeleteTemps(Iterable<File> files) async {
    for (final f in files) {
      await tryDeleteTemp(f);
    }
  }

  static Future<void> tryDeleteProcessedListingPhoto(
    ProcessedListingPhoto photo,
  ) async {
    await tryDeleteTemp(photo.full);
    await tryDeleteTemp(photo.thumbnail);
  }

  static Future<void> tryDeleteProcessedListingPhotos(
    Iterable<ProcessedListingPhoto> photos,
  ) async {
    for (final p in photos) {
      await tryDeleteProcessedListingPhoto(p);
    }
  }
}

class ImagePickResult {
  const ImagePickResult({
    required this.files,
    this.truncatedFromSelection = false,
  });

  final List<File> files;
  final bool truncatedFromSelection;
}
