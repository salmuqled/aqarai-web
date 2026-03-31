import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/models/auction/auction_bid.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';

/// Premium highest-bid block: very large type, gold accent, green glow when user leads.
class HighestBidWidget extends StatefulWidget {
  const HighestBidWidget({
    super.key,
    required this.lot,
    required this.bids,
    this.currentUserId,
  });

  final AuctionLot lot;
  final List<AuctionBid> bids;
  final String? currentUserId;

  @override
  State<HighestBidWidget> createState() => _HighestBidWidgetState();
}

class _HighestBidWidgetState extends State<HighestBidWidget>
    with TickerProviderStateMixin {
  double? _prevAmount;
  late final AnimationController _newHigh;
  late final AnimationController _leadGlow;

  @override
  void initState() {
    super.initState();
    _newHigh = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 640),
    );
    _leadGlow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _prevAmount = _displayAmount();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncLeadGlow());
  }

  @override
  void didUpdateWidget(covariant HighestBidWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _displayAmount();
    final prev = _prevAmount ?? next;
    final hasBids =
        widget.lot.highestBid != null && widget.lot.highestBid! > 0;
    final amountRose = next > prev + 1e-9;
    final highChanged = widget.lot.highestBid != oldWidget.lot.highestBid ||
        widget.lot.highestBidderId != oldWidget.lot.highestBidderId;
    if (hasBids && amountRose && highChanged) {
      HapticFeedback.mediumImpact();
      _newHigh.forward(from: 0);
    }
    _prevAmount = next;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncLeadGlow());
  }

  void _syncLeadGlow() {
    if (!mounted) return;
    final win = _userIsWinning(widget.currentUserId);
    if (win) {
      if (!_leadGlow.isAnimating) _leadGlow.repeat(reverse: true);
    } else {
      _leadGlow.stop();
      _leadGlow.value = 0;
    }
  }

  @override
  void dispose() {
    _newHigh.dispose();
    _leadGlow.dispose();
    super.dispose();
  }

  double _displayAmount() {
    final h = widget.lot.highestBid;
    if (h != null && h > 0) return h;
    return widget.lot.startingPrice;
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

  bool _userHasAnyBid(String? uid) {
    if (uid == null || uid.isEmpty) return false;
    return widget.bids.any((b) => b.userId == uid);
  }

  bool _userIsWinning(String? uid) {
    if (uid == null || uid.isEmpty) return false;
    final hb = widget.lot.highestBidderId;
    return hb != null && hb == uid;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final amount = _displayAmount();
    final hasBids = widget.lot.highestBid != null && widget.lot.highestBid! > 0;
    final uid = widget.currentUserId;
    final leading = _userIsWinning(uid);

    String? subMessage;
    var subIsPositive = false;
    if (uid != null && hasBids) {
      if (leading) {
        subMessage = ar ? 'أنت المتصدر' : 'You are in the lead';
        subIsPositive = true;
      } else if (_userHasAnyBid(uid)) {
        subMessage = ar ? 'تم تجاوز مزايدتك' : 'You have been outbid';
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: AnimatedBuilder(
          key: ValueKey<double>(amount),
          animation: Listenable.merge([_newHigh, _leadGlow]),
          builder: (context, _) {
            final v = _newHigh.value;
            final g = _leadGlow.value;
            final wave = math.sin(v * math.pi);
            final scale = 1.0 + 0.065 * wave;
            final flashOpacity = _newHigh.isDismissed ? 0.0 : 0.42 * wave;

            final shadows = <BoxShadow>[
              BoxShadow(
                color: AppColors.navy.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ];
            if (leading) {
              shadows.add(
                BoxShadow(
                  color: AuctionUiColors.winningGreen.withValues(
                    alpha: 0.38 + 0.22 * g,
                  ),
                  blurRadius: 22 + 14 * g,
                  spreadRadius: 1 + 2 * g,
                ),
              );
            }

            final card = Container(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.navy,
                    AppColors.navy.withValues(alpha: 0.88),
                    const Color(0xFF1A1A5C),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: leading
                      ? Color.lerp(
                          AuctionUiColors.winningGreen,
                          AuctionUiColors.winningGreenLight,
                          g,
                        )!
                      : AuctionUiColors.amber.withValues(alpha: 0.55),
                  width: leading ? 2.2 : 1.4,
                ),
                boxShadow: shadows,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    hasBids
                        ? (ar ? 'أعلى مزايدة' : 'Current highest bid')
                        : (ar ? 'الحد الأدنى للمزايدة' : 'Opening from'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AuctionUiColors.amber.withValues(alpha: 0.95),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _formatMoney(context, amount),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displayMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 44,
                      height: 1.05,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (subMessage != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      subMessage,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: subIsPositive
                            ? AuctionUiColors.winningGreenLight
                            : Colors.orangeAccent.shade100,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            );

            return Transform.scale(
              scale: scale,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  card,
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          color: AuctionUiColors.amber.withValues(
                            alpha: flashOpacity * 0.85,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
