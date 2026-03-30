import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';

/// Browser / clipboard / Instagram deep link helpers for manual posting flow.
abstract final class InstagramPostActions {
  InstagramPostActions._();

  static void _snack(BuildContext context, String message, {bool error = false}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red.shade800 : null,
      ),
    );
  }

  /// Picker to open one of several carousel image URLs (no in-app preview).
  static Future<void> openImageUrls(
    List<String> urls,
    BuildContext context,
  ) async {
    final loc = AppLocalizations.of(context);
    final clean = urls.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (clean.isEmpty) {
      _snack(
        context,
        loc?.instagramPostNoImageUrl ?? 'No image URL',
        error: true,
      );
      return;
    }
    if (clean.length == 1) {
      await openImage(clean.first, context);
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc?.instagramPostOpenImages ?? 'Open images'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < clean.length; i++)
                ListTile(
                  leading: Icon(Icons.image_outlined, color: Colors.blue.shade700),
                  title: Text(
                    loc?.instagramCarouselSlideLabel(i + 1) ?? 'Slide ${i + 1}',
                  ),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () {
                    Navigator.pop(ctx);
                    openImage(clean[i], context);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(loc?.cancel ?? 'Cancel'),
          ),
        ],
      ),
    );
  }

  /// Opens [url] in the external browser (image URL).
  static Future<void> openImage(String? url, BuildContext context) async {
    final loc = AppLocalizations.of(context);
    if (url == null || url.trim().isEmpty) {
      _snack(
        context,
        loc?.instagramPostNoImageUrl ?? 'No image URL',
        error: true,
      );
      return;
    }
    try {
      final uri = Uri.parse(url.trim());
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        _snack(
          context,
          loc?.instagramPostOpenFailed ?? 'Could not open link',
          error: true,
        );
      }
    } catch (_) {
      if (context.mounted) {
        _snack(
          context,
          loc?.instagramPostOpenFailed ?? 'Could not open link',
          error: true,
        );
      }
    }
  }

  /// Copies [caption] and shows confirmation snackbar.
  static Future<void> copyCaption(String caption, BuildContext context) async {
    final loc = AppLocalizations.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: caption));
      if (context.mounted) {
        _snack(context, loc?.instagramCaptionCopied ?? 'Caption copied');
      }
    } catch (_) {
      if (context.mounted) {
        _snack(
          context,
          loc?.errorLabel ?? 'Error',
          error: true,
        );
      }
    }
  }

  /// Tries `instagram://app`, then falls back to instagram.com.
  static Future<void> openInstagram(BuildContext context) async {
    final loc = AppLocalizations.of(context);
    try {
      final appUri = Uri.parse('instagram://app');
      final launched = await launchUrl(
        appUri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) return;
    } catch (_) {
      // Fall through to web.
    }
    try {
      final web = Uri.parse('https://www.instagram.com');
      final ok = await launchUrl(web, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        _snack(
          context,
          loc?.instagramOpenAppFailed ?? 'Could not open Instagram',
          error: true,
        );
      }
    } catch (_) {
      if (context.mounted) {
        _snack(
          context,
          loc?.instagramOpenAppFailed ?? 'Could not open Instagram',
          error: true,
        );
      }
    }
  }
}
