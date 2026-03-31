import 'package:flutter/material.dart';

/// Secondary smart CTA — opens AI assistant chat. Lighter than primary search.
class SmartAssistantCta extends StatefulWidget {
  const SmartAssistantCta({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.leadingIcon = Icons.auto_awesome_rounded,
    this.trailingIcon = Icons.chat_bubble_outline_rounded,
    this.accentColor,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final IconData leadingIcon;
  final IconData trailingIcon;
  final Color? accentColor;

  static const double _radius = 18;

  @override
  State<SmartAssistantCta> createState() => _SmartAssistantCtaState();
}

class _SmartAssistantCtaState extends State<SmartAssistantCta> {
  bool _pressed = false;

  static const Color _inkBlue = Color(0xFF2563EB);
  static const Color _textMain = Color(0xFF1E293B);
  static const Color _textMuted = Color(0xFF64748B);

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor ?? _inkBlue;
    final semanticsLabel = '${widget.title}. ${widget.subtitle}';

    return Semantics(
      button: true,
      label: semanticsLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.985 : 1,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: _pressed ? 0.88 : 1,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(SmartAssistantCta._radius),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFDCEBFF),
                    Color(0xFFF0F7FF),
                    Color(0xFFFFFFFF),
                  ],
                  stops: [0.0, 0.45, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1A2B4D).withValues(alpha: 0.07),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                  BoxShadow(
                    color: accent.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.72),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.12),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        widget.leadingIcon,
                        size: 20,
                        color: accent.withValues(alpha: 0.95),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.25,
                            fontWeight: FontWeight.w500,
                            color: _textMain,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.2,
                            fontWeight: FontWeight.w400,
                            color: _textMuted.withValues(alpha: 0.95),
                            letterSpacing: -0.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    widget.trailingIcon,
                    size: 20,
                    color: _textMuted.withValues(alpha: 0.55),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
