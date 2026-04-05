import 'package:flutter/material.dart';

/// Single rendering pipeline for Terms & Conditions body text (e.g. [addPropertyTermsDialogBody]).
class TermsContentView extends StatelessWidget {
  const TermsContentView({
    super.key,
    required this.bodyText,
    this.padding = const EdgeInsets.fromLTRB(20, 20, 20, 24),
    this.paragraphSpacing = 14,
    this.bodyFontSize = 15,
    this.wrapInDecoratedCard = false,
  });

  final String bodyText;
  final EdgeInsets padding;
  final double paragraphSpacing;
  final double bodyFontSize;

  /// When true, wraps content in the same rounded card used on [TermsConditionsPage].
  final bool wrapInDecoratedCard;

  static List<String> paragraphsFromBody(String body) => body
      .split(RegExp(r'\n\n+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  static const Color _bodyColor = Color(0xFF1A1A1A);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final paragraphs = paragraphsFromBody(bodyText);

    final textStyle = theme.textTheme.bodyLarge?.copyWith(
          fontSize: bodyFontSize,
          height: 1.55,
          color: _bodyColor,
        ) ??
        TextStyle(
          fontSize: bodyFontSize,
          height: 1.55,
          color: _bodyColor,
        );

    Widget content = Padding(
      padding: padding,
      child: Directionality(
        textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < paragraphs.length; i++) ...[
              if (i > 0) SizedBox(height: paragraphSpacing),
              SelectableText(
                paragraphs[i],
                style: textStyle,
                textAlign: TextAlign.start,
              ),
            ],
          ],
        ),
      ),
    );

    if (!wrapInDecoratedCard) {
      return content;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: content,
    );
  }
}
