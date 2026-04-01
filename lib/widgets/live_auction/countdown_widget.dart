import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';

/// LIVE / WAITING / CLOSED + countdown using [serverNow] (NTP-adjusted).
class CountdownWidget extends StatefulWidget {
  const CountdownWidget({
    super.key,
    required this.lot,
    required this.serverNow,
  });

  final AuctionLot lot;
  final DateTime serverNow;

  @override
  State<CountdownWidget> createState() => _CountdownWidgetState();
}

class _CountdownWidgetState extends State<CountdownWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPulse());
  }

  @override
  void didUpdateWidget(covariant CountdownWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPulse());
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  LiveAuctionPhase _phase() {
    switch (widget.lot.status) {
      case LotStatus.sold:
      case LotStatus.closed:
      case LotStatus.pendingAdminReview:
      case LotStatus.rejected:
      case LotStatus.ended:
        return LiveAuctionPhase.closed;
      case LotStatus.pending:
        return LiveAuctionPhase.waiting;
      case LotStatus.active:
        if (widget.serverNow.isBefore(widget.lot.startTime)) {
          return LiveAuctionPhase.waiting;
        }
        if (!widget.serverNow.isBefore(widget.lot.endsAt)) {
          return LiveAuctionPhase.closed;
        }
        return LiveAuctionPhase.live;
    }
  }

  Duration _remaining() {
    final diff = widget.lot.endsAt.difference(widget.serverNow);
    return diff.isNegative ? Duration.zero : diff;
  }

  bool _isUrgentCountdown() {
    if (_phase() != LiveAuctionPhase.live) return false;
    final r = _remaining();
    return r > Duration.zero && r < const Duration(seconds: 10);
  }

  void _syncPulse() {
    if (!mounted) return;
    final urgent = _isUrgentCountdown();
    if (urgent) {
      if (!_pulse.isAnimating) {
        _pulse.repeat(reverse: true);
      }
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  String _formatDuration(Duration d) {
    if (d <= Duration.zero) return '00:00:00';
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = _phase();
    final ar = Localizations.localeOf(context).languageCode == 'ar';

    late final String label;
    late final Color badgeColor;
    late final Color onBadge;

    switch (phase) {
      case LiveAuctionPhase.live:
        label = ar ? 'مباشر' : 'LIVE';
        badgeColor = AuctionUiColors.amber;
        onBadge = AppColors.navy;
      case LiveAuctionPhase.waiting:
        label = ar ? 'في الانتظار' : 'WAITING';
        badgeColor = AuctionUiColors.amberDeep;
        onBadge = Colors.white;
      case LiveAuctionPhase.closed:
        label = ar ? 'مغلق' : 'CLOSED';
        badgeColor = theme.colorScheme.surfaceContainerHighest;
        onBadge = theme.colorScheme.onSurfaceVariant;
    }

    final remaining = phase == LiveAuctionPhase.live ? _remaining() : null;
    final urgent = _isUrgentCountdown();
    final timeColor =
        urgent ? AuctionUiColors.urgencyRed : AppColors.navy;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(22),
              boxShadow: phase == LiveAuctionPhase.live
                  ? [
                      BoxShadow(
                        color: AuctionUiColors.amber.withValues(alpha: 0.45),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: onBadge,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ar ? 'الوقت المتبقي' : 'Time remaining',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) {
                    final scale = urgent ? 1.0 + 0.04 * _pulse.value : 1.0;
                    return Transform.scale(
                      scale: scale,
                      alignment: Alignment.centerLeft,
                      child: child,
                    );
                  },
                  child: Text(
                    remaining != null
                        ? _formatDuration(remaining)
                        : (phase == LiveAuctionPhase.closed
                            ? (ar ? 'انتهى العرض' : 'Ended')
                            : (ar ? 'لم يبدأ بعد' : 'Not started')),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: timeColor,
                    ),
                  ),
                ),
                if (remaining != null &&
                    remaining > Duration.zero &&
                    remaining < const Duration(minutes: 1)) ...[
                  const SizedBox(height: 6),
                  Text(
                    ar ? '⏳ باقي أقل من دقيقة' : '⏳ Less than a minute left',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: AuctionUiColors.urgencyRed,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum LiveAuctionPhase { live, waiting, closed }
