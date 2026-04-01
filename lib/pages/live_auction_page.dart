import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/services/auction/auction_analytics_service.dart';
import 'package:aqarai_app/services/auction/auction_time_service.dart';
import 'package:aqarai_app/services/auction/live_auction_combined_stream.dart';
import 'package:aqarai_app/widgets/live_auction/auction_header_widget.dart';
import 'package:aqarai_app/widgets/live_auction/bid_action_widget.dart';
import 'package:aqarai_app/widgets/live_auction/bids_list_widget.dart';
import 'package:aqarai_app/widgets/live_auction/countdown_widget.dart';
import 'package:aqarai_app/widgets/live_auction/highest_bid_widget.dart';

/// Production live auction UI: merged Firestore stream + hybrid clock + callable bids only.
class LiveAuctionPage extends StatefulWidget {
  const LiveAuctionPage({
    super.key,
    required this.auctionId,
    required this.lotId,
  });

  final String auctionId;
  final String lotId;

  @override
  State<LiveAuctionPage> createState() => _LiveAuctionPageState();
}

class _LiveAuctionPageState extends State<LiveAuctionPage>
    with WidgetsBindingObserver {
  StreamSubscription<LiveAuctionCombinedState>? _sub;
  LiveAuctionCombinedState? _combined;
  late final ValueNotifier<DateTime> _serverNow;
  Timer? _clockTimer;

  String? _prevCurrentHighBidderId;
  bool _outbidBannerVisible = false;
  Timer? _outbidBannerTimer;

  Future<void> _syncClockAndRefresh() async {
    await AuctionTimeService.instance.sync();
    if (!mounted) return;
    _serverNow.value = AuctionTimeService.instance.now();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _serverNow = ValueNotifier<DateTime>(AuctionTimeService.instance.now());

    unawaited(_syncClockAndRefresh());
    AuctionTimeService.instance.startPeriodicResync();

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _serverNow.value = AuctionTimeService.instance.now();
    });

    _sub = watchLiveAuctionCombined(widget.lotId, bidLimit: 20).listen((state) {
      if (!mounted) return;
      final lot = state.lot;
      if (lot != null &&
          lot.auctionId == widget.auctionId &&
          state.lotError == null) {
        _detectOutbid(lot);
      }
      setState(() => _combined = state);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        AuctionAnalyticsService.logAuctionViewed(lotId: widget.lotId),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncClockAndRefresh());
    }
  }

  void _detectOutbid(AuctionLot lot) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _prevCurrentHighBidderId = lot.currentHighBidderId;
      return;
    }
    final cur = lot.currentHighBidderId;
    final had = _prevCurrentHighBidderId;
    if (had == uid &&
        cur != null &&
        cur.isNotEmpty &&
        cur != uid) {
      _prevCurrentHighBidderId = cur;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showOutbidBanner();
      });
      return;
    }
    _prevCurrentHighBidderId = cur;
  }

  void _showOutbidBanner() {
    if (!mounted) return;
    _outbidBannerTimer?.cancel();
    setState(() => _outbidBannerVisible = true);
    _outbidBannerTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _outbidBannerVisible = false);
    });
  }

  void _dismissOutbidBanner() {
    _outbidBannerTimer?.cancel();
    setState(() => _outbidBannerVisible = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AuctionTimeService.instance.stopPeriodicResync();
    _sub?.cancel();
    _clockTimer?.cancel();
    _outbidBannerTimer?.cancel();
    _serverNow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context)!;
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final state = _combined;

    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FB),
      appBar: AppBar(
        title: Text(ar ? 'المزاد المباشر' : 'Live auction'),
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: AppColors.navy,
        elevation: 0,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: AuctionTimeService.instance.reliableTime,
            builder: (context, _) {
              if (AuctionTimeService.instance.reliableTime.value) {
                return const SizedBox.shrink();
              }
              return _ClockWarningStrip(ar: ar);
            },
          ),
          if (_outbidBannerVisible)
            _OutbidTopBanner(
              message: loc.liveAuctionOutbidBanner,
              onDismiss: _dismissOutbidBanner,
            ),
          Expanded(
            child: _buildBody(context, theme, ar, state),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ThemeData theme,
    bool ar,
    LiveAuctionCombinedState? state,
  ) {
    if (state == null ||
        (!state.lotReady && state.lot == null && state.lotError == null)) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.hasLotError) {
      return _ErrorState(
        message: ar
            ? 'تعذّر تحميل بيانات العنصر'
            : 'Could not load lot',
        detail: state.lotError.toString(),
      );
    }

    final lot = state.lot;
    if (lot == null) {
      return _ErrorState(
        message: ar ? 'العنصر غير موجود' : 'Lot not found',
      );
    }

    if (lot.auctionId != widget.auctionId) {
      return _ErrorState(
        message: ar
            ? 'معرّف المزاد لا يطابق هذا العنصر'
            : 'Auction ID does not match this lot',
      );
    }

    if (state.hasBidsError) {
      return _ErrorState(
        message: ar ? 'تعذّر تحميل المزايدات' : 'Could not load bids',
        detail: state.bidsError.toString(),
      );
    }

    final bids = state.bids;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ValueListenableBuilder<DateTime>(
                  valueListenable: _serverNow,
                  builder: (context, now, _) {
                    return AuctionHeaderWidget(
                      lot: lot,
                      serverNow: now,
                    );
                  },
                ),
                StreamBuilder<User?>(
                  stream: FirebaseAuth.instance.authStateChanges(),
                  builder: (context, userSnap) {
                    return HighestBidWidget(
                      lot: lot,
                      bids: bids,
                      currentUserId: userSnap.data?.uid,
                    );
                  },
                ),
                ValueListenableBuilder<DateTime>(
                  valueListenable: _serverNow,
                  builder: (context, now, _) {
                    return CountdownWidget(
                      key: ValueKey<int>(lot.endsAt.millisecondsSinceEpoch),
                      lot: lot,
                      serverNow: now,
                    );
                  },
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 22,
                        decoration: BoxDecoration(
                          color: AuctionUiColors.amber,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        ar ? 'المزايدات الحية' : 'Live bids',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppColors.navy,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 280,
                  child: !state.bidsReady && bids.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : BidsListWidget(bids: bids),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
        ValueListenableBuilder<DateTime>(
          valueListenable: _serverNow,
          builder: (context, now, _) {
            return BidActionWidget(
              auctionId: widget.auctionId,
              lotId: widget.lotId,
              lot: lot,
              serverNow: now,
            );
          },
        ),
      ],
    );
  }
}

class _OutbidTopBanner extends StatelessWidget {
  const _OutbidTopBanner({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.deepOrange.shade800,
      elevation: 4,
      child: InkWell(
        onTap: onDismiss,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.campaign_outlined, color: Colors.orange.shade100, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, color: Colors.white.withValues(alpha: 0.92)),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClockWarningStrip extends StatelessWidget {
  const _ClockWarningStrip({required this.ar});

  final bool ar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.schedule_outlined, size: 20, color: Colors.amber.shade900),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ar
                    ? 'تعذّر مزامنة الوقت مع الخادم — يُستخدم وقت الجهاز. قد يؤثر ذلك على العد التنازلي.'
                    : 'Could not sync time with the server — using device time. Countdown may be less accurate.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.amber.shade900,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    this.detail,
  });

  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
