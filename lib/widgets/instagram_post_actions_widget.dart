import 'package:flutter/material.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/caption_usage_context.dart';
import 'package:aqarai_app/models/caption_variant_score.dart';
import 'package:aqarai_app/services/caption_usage_log_service.dart';
import 'package:aqarai_app/services/instagram_post_actions.dart';

/// Manual Instagram flow: image URL(s) (browser) + caption (clipboard) + open app.
///
/// Does **not** render images. Use [imageUrls] for carousel (4 slides); otherwise [imageUrl].
///
/// When [rankedCaptionVariants] is set (e.g. carousel), shows A/B/C picker with scoring order.
class InstagramPostActionsWidget extends StatefulWidget {
  InstagramPostActionsWidget({
    super.key,
    this.imageUrl,
    this.imageUrls,
    required this.caption,
    this.rankedCaptionVariants,
    this.captionUsageContext,
  }) : assert(
          (imageUrl != null && imageUrl.trim().isNotEmpty) ||
              (imageUrls?.any((e) => e.trim().isNotEmpty) ?? false),
          'Provide imageUrl or non-empty imageUrls',
        );

  final String? imageUrl;
  final List<String>? imageUrls;
  final String caption;
  final List<CaptionVariantScore>? rankedCaptionVariants;
  final CaptionUsageContext? captionUsageContext;

  @override
  State<InstagramPostActionsWidget> createState() =>
      _InstagramPostActionsWidgetState();
}

class _InstagramPostActionsWidgetState extends State<InstagramPostActionsWidget> {
  late String _activeCaption;
  late String _selectedVariantId;

  @override
  void initState() {
    super.initState();
    final v = widget.rankedCaptionVariants;
    if (v != null && v.isNotEmpty) {
      _activeCaption = v.first.caption;
      _selectedVariantId = v.first.variantId;
    } else {
      _activeCaption = widget.caption;
      _selectedVariantId = 'primary';
    }
  }

  bool get _carousel =>
      widget.imageUrls != null &&
      widget.imageUrls!.where((e) => e.trim().isNotEmpty).length > 1;

  List<String> get _urls {
    if (widget.imageUrls != null && widget.imageUrls!.isNotEmpty) {
      return widget.imageUrls!
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final u = widget.imageUrl?.trim() ?? '';
    return u.isEmpty ? const <String>[] : [u];
  }

  String _variantTitle(AppLocalizations loc, String id) {
    switch (id) {
      case 'A':
        return loc.instagramCaptionVariantRowA;
      case 'B':
        return loc.instagramCaptionVariantRowB;
      case 'C':
        return loc.instagramCaptionVariantRowC;
      default:
        return id;
    }
  }

  Future<void> _logCaptionUsage(String variantId, String captionText) async {
    final ctx = widget.captionUsageContext;
    if (ctx == null) return;
    await CaptionUsageLogService.logUsage(
      captionId: variantId,
      captionText: captionText,
      area: ctx.area,
      propertyType: ctx.propertyType,
      demandLevel: ctx.demandLevel,
      dealsCount: ctx.dealsCount,
    );
  }

  Future<void> _copyActiveCaption(BuildContext context) async {
    await InstagramPostActions.copyCaption(_activeCaption, context);
    if (widget.rankedCaptionVariants != null &&
        widget.rankedCaptionVariants!.isNotEmpty) {
      await _logCaptionUsage(_selectedVariantId, _activeCaption);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final urls = _urls;
    final hasUrl = urls.isNotEmpty;
    final variants = widget.rankedCaptionVariants;

    final headline = _carousel
        ? loc.instagramPostCarouselHeadline(urls.length)
        : loc.instagramPostCreatedHeadline;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          headline,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 16),
        if (variants != null && variants.isNotEmpty) ...[
          Text(
            loc.instagramCaptionVariantBestTitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.indigo.shade900,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () async {
                  final best = variants.first;
                  setState(() {
                    _selectedVariantId = best.variantId;
                    _activeCaption = best.caption;
                  });
                  await _logCaptionUsage(best.variantId, best.caption);
                  if (context.mounted) {
                    await InstagramPostActions.copyCaption(best.caption, context);
                  }
                },
                child: Text(loc.instagramCaptionVariantUseBest),
              ),
              OutlinedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(loc.instagramCaptionVariantManualHint)),
                  );
                },
                child: Text(loc.instagramCaptionVariantManualPick),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...variants.asMap().entries.map((e) {
            final i = e.key;
            final item = e.value;
            final best = i == 0;
            final selected = item.variantId == _selectedVariantId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: selected
                    ? Colors.indigo.shade50
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    setState(() {
                      _selectedVariantId = item.variantId;
                      _activeCaption = item.caption;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _variantTitle(loc, item.variantId),
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: Colors.grey.shade900,
                                ),
                              ),
                            ),
                            if (best)
                              Text(
                                '⭐',
                                style: TextStyle(fontSize: 16),
                              ),
                            if (selected)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 6,
                                ),
                                child: Icon(
                                  Icons.check_circle,
                                  size: 18,
                                  color: Colors.indigo.shade700,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.caption,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: Colors.grey.shade800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          loc.instagramCaptionVariantScore(
                            item.score.toStringAsFixed(2),
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
        ],
        Text(
          loc.instagramPostCaptionPreviewLabel,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade700,
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          _activeCaption,
          style: const TextStyle(fontSize: 14, height: 1.4),
        ),
        if (!hasUrl) ...[
          const SizedBox(height: 8),
          Text(
            loc.instagramPostNoImageUrl,
            style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: hasUrl
              ? () {
                  if (_carousel || urls.length > 1) {
                    InstagramPostActions.openImageUrls(urls, context);
                  } else {
                    InstagramPostActions.openImage(urls.first, context);
                  }
                }
              : null,
          icon: const Icon(Icons.open_in_browser_outlined),
          label: Text(
            _carousel || urls.length > 1
                ? loc.instagramPostOpenImages
                : loc.instagramPostOpenImage,
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          onPressed: () => _copyActiveCaption(context),
          icon: const Icon(Icons.copy_outlined),
          label: Text(loc.instagramPostCopyCaption),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => InstagramPostActions.openInstagram(context),
          icon: const Icon(Icons.camera_alt_outlined),
          label: Text(loc.instagramPostOpenInstagram),
        ),
      ],
    );
  }
}
