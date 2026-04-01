import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/models/auction/auction_bid.dart';

/// Real-time bids list (newest first). Highlights latest row; optional haptic on new top bid.
class BidsListWidget extends StatefulWidget {
  const BidsListWidget({
    super.key,
    required this.bids,
    this.enableHapticOnNewBid = true,
  });

  final List<AuctionBid> bids;
  final bool enableHapticOnNewBid;

  @override
  State<BidsListWidget> createState() => _BidsListWidgetState();
}

class _BidsListWidgetState extends State<BidsListWidget> {
  String? _lastTopBidId;

  @override
  void didUpdateWidget(covariant BidsListWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final top = widget.bids.isNotEmpty ? widget.bids.first.id : null;
    if (top != null &&
        _lastTopBidId != null &&
        top != _lastTopBidId &&
        widget.enableHapticOnNewBid) {
      HapticFeedback.mediumImpact();
    }
    _lastTopBidId = top;
  }

  @override
  void initState() {
    super.initState();
    _lastTopBidId = widget.bids.isNotEmpty ? widget.bids.first.id : null;
  }

  String _formatMoney(BuildContext context, double value) {
    final locale = Localizations.localeOf(context).toString();
    final fmt = NumberFormat.currency(
      locale: locale,
      symbol: '',
      decimalDigits: value == value.roundToDouble() ? 0 : 3,
    );
    final suffix = Localizations.localeOf(context).languageCode == 'ar'
        ? ' د.ك'
        : ' KWD';
    return '${fmt.format(value)}$suffix';
  }

  String _formatTime(BuildContext context, DateTime t) {
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMMMd(locale).add_jms().format(t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ar = Localizations.localeOf(context).languageCode == 'ar';

    if (widget.bids.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.gavel_outlined,
                size: 44,
                color: AppColors.navy.withValues(alpha: 0.45),
              ),
              const SizedBox(height: 14),
              Text(
                ar ? 'ابدأ أول مزايدة الآن' : 'Be the first to bid now',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      itemCount: widget.bids.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final bid = widget.bids[index];
        final isNewest = index == 0;
        final tile = AnimatedContainer(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: isNewest
                ? Color.lerp(
                    AppColors.navy.withValues(alpha: 0.1),
                    Colors.amber.shade100.withValues(alpha: 0.65),
                    0.35,
                  )
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  ),
            border: isNewest
                ? Border.all(
                    color: AppColors.navy.withValues(alpha: 0.22),
                    width: 1.2,
                  )
                : null,
            boxShadow: isNewest
                ? [
                    BoxShadow(
                      color: AppColors.navy.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {},
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    if (isNewest)
                      Container(
                        width: 4,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              AppColors.navy,
                              Colors.amber.shade700,
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      )
                    else
                      const SizedBox(width: 4),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _formatMoney(context, bid.amount),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: AppColors.navy,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _formatTime(context, bid.createdAt),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isNewest)
                      Chip(
                        label: Text(
                          ar ? 'الأحدث' : 'Latest',
                          style: theme.textTheme.labelSmall,
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );

        if (isNewest) {
          return TweenAnimationBuilder<double>(
            key: ValueKey<String>(bid.id),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) {
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 6 * (1 - t)),
                  child: child,
                ),
              );
            },
            child: tile,
          );
        }
        return tile;
      },
    );
  }
}
