import 'dart:async';

// Auction details — premium live bidding UI.
// Firestore: `lots/{lotId}` + subcollection `lots/{lotId}/bids`.
// Callable: this repo exports `placeAuctionBid` (us-central1). Set [_kPlaceBidCallable]
// to `placeBid` if your backend uses that name.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/widgets/auction/auction_lot_rejection_strip.dart';
import 'package:aqarai_app/services/auction/auction_analytics_service.dart';
import 'package:aqarai_app/services/auction/auction_time_service.dart';
import 'package:aqarai_app/services/auction/bid_service.dart';

/// Firebase callable name for bid placement (must match Cloud Functions export).
const String _kPlaceBidCallable = 'placeAuctionBid';

/// Same region as [BidService] / other callables in this app.
String _functionsRegion() => 'us-central1';

/// Production-level auction lot details + live bidding.
///
/// Pass [auctionId] if known; otherwise it is read from `lots/{lotId}.auctionId`
/// once the snapshot loads (required before placing a bid).
class AuctionDetailsPage extends StatefulWidget {
  const AuctionDetailsPage({
    super.key,
    required this.lotId,
    this.auctionId,
  });

  final String lotId;
  final String? auctionId;

  @override
  State<AuctionDetailsPage> createState() => _AuctionDetailsPageState();
}

class _AuctionDetailsPageState extends State<AuctionDetailsPage>
    with WidgetsBindingObserver {
  Timer? _clockTimer;
  DateTime _clockNow = DateTime.now();

  String? _prevHighBidderId;
  bool _outbidBannerVisible = false;
  Timer? _outbidBannerTimer;
  bool _newBidBannerVisible = false;
  Timer? _newBidBannerTimer;
  double? _trackedHighBid;
  int _trackedBidCount = -1;
  bool _lotSnapshotPrimed = false;

  final PageController _galleryController = PageController();
  int _galleryIndex = 0;

  final TextEditingController _bidAmountController = TextEditingController();
  bool _placingBid = false;
  String? _lastBidError;
  String? _lastBidSuccess;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AuctionTimeService.instance.sync());
    AuctionTimeService.instance.startPeriodicResync();
    _clockNow = AuctionTimeService.instance.now();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _clockNow = AuctionTimeService.instance.now());
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        AuctionAnalyticsService.logAuctionViewed(lotId: widget.lotId),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AuctionTimeService.instance.stopPeriodicResync();
    _clockTimer?.cancel();
    _outbidBannerTimer?.cancel();
    _newBidBannerTimer?.cancel();
    _galleryController.dispose();
    _bidAmountController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AuctionTimeService.instance.sync());
    }
  }

  void _dismissOutbidBanner() {
    _outbidBannerTimer?.cancel();
    setState(() => _outbidBannerVisible = false);
  }

  void _dismissNewBidBanner() {
    _newBidBannerTimer?.cancel();
    setState(() => _newBidBannerVisible = false);
  }

  void _onLotSnapshot(Map<String, dynamic> d) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final bidder = _currentHighBidderId(d);

    if (uid == null) {
      _prevHighBidderId = bidder;
    } else {
      final had = _prevHighBidderId;
      final cur = bidder;
      if (had == uid &&
          cur != null &&
          cur.isNotEmpty &&
          cur != uid) {
        _prevHighBidderId = cur;
        _outbidBannerTimer?.cancel();
        if (mounted) {
          setState(() => _outbidBannerVisible = true);
          HapticFeedback.heavyImpact();
          _outbidBannerTimer = Timer(const Duration(seconds: 8), () {
            if (mounted) setState(() => _outbidBannerVisible = false);
          });
        }
      } else {
        _prevHighBidderId = cur;
      }
    }

    final high = _currentHighBid(d);
    final bc = _readBidCount(d);
    if (_lotSnapshotPrimed) {
      final highUp = high > (_trackedHighBid ?? -1) + 1e-9;
      final countUp = bc > _trackedBidCount;
      if ((highUp || countUp) && (high > 0 || bc > _trackedBidCount)) {
        _newBidBannerTimer?.cancel();
        if (mounted) {
          setState(() => _newBidBannerVisible = true);
          HapticFeedback.selectionClick();
          _newBidBannerTimer = Timer(const Duration(seconds: 5), () {
            if (mounted) setState(() => _newBidBannerVisible = false);
          });
        }
      }
    }
    _lotSnapshotPrimed = true;
    _trackedHighBid = high;
    _trackedBidCount = bc;
  }

  DocumentReference<Map<String, dynamic>> get _lotRef =>
      FirebaseFirestore.instance.collection('lots').doc(widget.lotId);

  Stream<DocumentSnapshot<Map<String, dynamic>>> get _lotStream =>
      _lotRef.snapshots();

  Query<Map<String, dynamic>> get _recentBidsQuery => _lotRef
      .collection('bids')
      .orderBy('createdAt', descending: true)
      .limit(5);

  bool get _isArabic {
    try {
      return Localizations.localeOf(context).languageCode == 'ar';
    } catch (_) {
      return true;
    }
  }

  String _money(double value) {
    final locale = Localizations.localeOf(context).toString();
    final fmt = NumberFormat.currency(
      locale: locale,
      symbol: '',
      decimalDigits: value == value.roundToDouble() ? 0 : 3,
    );
    final suffix = _isArabic ? ' د.ك' : ' KWD';
    return '${fmt.format(value)}$suffix';
  }

  String _anonymizeUid(String? uid) {
    if (uid == null || uid.length < 4) return 'User***';
    return 'User${uid.substring(0, 4)}***';
  }

  DateTime? _readEndsAt(Map<String, dynamic> d) {
    final a = d['endsAt'];
    if (a is Timestamp) return a.toDate();
    return null;
  }

  double _readDouble(dynamic v, [double fallback = 0]) {
    if (v is num && v.isFinite) return v.toDouble();
    return fallback;
  }

  double? _readNullableDouble(dynamic v) {
    if (v is num && v.isFinite) return v.toDouble();
    return null;
  }

  int _readBidCount(Map<String, dynamic> d) {
    final c = d['bidCount'];
    if (c is int) return c;
    if (c is num) return c.round();
    return 0;
  }

  double _currentHighBid(Map<String, dynamic> d) {
    return _readNullableDouble(d['currentHighBid']) ?? 0;
  }

  String? _currentHighBidderId(Map<String, dynamic> d) {
    final a = d['currentHighBidderId']?.toString();
    if (a != null && a.isNotEmpty) return a;
    return null;
  }

  List<String> _imageUrls(Map<String, dynamic> d) {
    final imgs = d['images'];
    if (imgs is List) {
      return imgs.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList();
    }
    final single = d['image']?.toString();
    if (single != null && single.isNotEmpty) return [single];
    return [];
  }

  bool _isLotEnded(Map<String, dynamic> d, DateTime end) {
    final status = d['status']?.toString().toLowerCase() ?? '';
    if (status == 'closed' ||
        status == 'sold' ||
        status == 'cancelled' ||
        status == 'ended' ||
        status == 'pending_admin_review' ||
        status == 'rejected') {
      return true;
    }
    return !_clockNow.isBefore(end);
  }

  double _minimumNextBid(Map<String, dynamic> d) {
    final start = _readDouble(d['startingPrice']);
    final inc = _readDouble(d['minIncrement']);
    final high = _currentHighBid(d);
    if (high <= 0 || high < start) return start;
    return high + inc;
  }

  void _syncBidFieldToMinimum(Map<String, dynamic> d) {
    final min = _minimumNextBid(d);
    final t = _bidAmountController.text.trim().replaceAll(',', '.');
    final parsed = double.tryParse(t);
    if (parsed == null || parsed < min - 1e-9) {
      _bidAmountController.text = _plainNumber(min);
    }
  }

  String _plainNumber(double v) {
    if (v == v.roundToDouble()) return v.round().toString();
    return v.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '');
  }

  Future<void> _placeBid(String auctionId, Map<String, dynamic> lotData) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _lastBidError = _isArabic ? 'يجب تسجيل الدخول' : 'Sign in required');
      return;
    }

    final raw = _bidAmountController.text.trim().replaceAll(',', '.');
    final amount = double.tryParse(raw);
    if (amount == null || !amount.isFinite) {
      setState(() => _lastBidError = _isArabic ? 'أدخل مبلغاً صالحاً' : 'Enter a valid amount');
      return;
    }

    final min = _minimumNextBid(lotData);
    if (amount + 1e-9 < min) {
      setState(() => _lastBidError =
          _isArabic ? 'المزايدة أقل من الحد الأدنى' : 'Below minimum bid');
      return;
    }

    setState(() {
      _placingBid = true;
      _lastBidError = null;
      _lastBidSuccess = null;
    });

    try {
      final callable = FirebaseFunctions.instanceFor(region: _functionsRegion())
          .httpsCallable(_kPlaceBidCallable);
      final res = await callable.call<dynamic>({
        'auctionId': auctionId,
        'lotId': widget.lotId,
        'amount': amount,
        'clientRequestId': BidService.newClientRequestId(),
      });

      final data = res.data;
      if (data is Map && data['success'] == true) {
        if (!mounted) return;
        setState(() {
          _lastBidSuccess = _isArabic ? 'تم تسجيل مزايدتك بنجاح' : 'Bid placed successfully';
        });
        HapticFeedback.mediumImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_lastBidSuccess!),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AuctionUiColors.winningGreen,
          ),
        );
      } else {
        final msg = data is Map ? data['message']?.toString() : null;
        setState(() => _lastBidError =
            msg ?? (_isArabic ? 'تعذّر تنفيذ المزايدة' : 'Could not place bid'));
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() => _lastBidError = _mapCfError(e));
    } catch (e) {
      setState(() => _lastBidError = e.toString());
    } finally {
      if (mounted) setState(() => _placingBid = false);
    }
  }

  String _mapCfError(FirebaseFunctionsException e) {
    final code = e.code;
    final m = (e.message ?? '').toLowerCase();
    if (code == 'failed-precondition') {
      if (m.contains('end') || m.contains('ended')) {
        return _isArabic ? 'انتهى المزاد' : 'Auction ended';
      }
      if (m.contains('increment') || m.contains('minimum')) {
        return _isArabic ? 'المزايدة أقل من المطلوب' : 'Bid too low';
      }
      return _isArabic ? 'تعذّر تنفيذ المزايدة' : 'Could not place bid';
    }
    if (code == 'unauthenticated') {
      return _isArabic ? 'يجب تسجيل الدخول' : 'Sign in required';
    }
    return e.message ?? (_isArabic ? 'حدث خطأ' : 'Error');
  }

  void _bumpBid(double delta, Map<String, dynamic> lotData) {
    final min = _minimumNextBid(lotData);
    final raw = _bidAmountController.text.trim().replaceAll(',', '.');
    final current = double.tryParse(raw) ?? min;
    final next = (current < min ? min : current) + delta;
    _bidAmountController.text = _plainNumber(next);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      extendBody: true,
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: Text(
          _isArabic ? 'تفاصيل المزاد' : 'Auction details',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _lotStream,
        builder: (context, lotSnap) {
          if (lotSnap.connectionState == ConnectionState.waiting && !lotSnap.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.navy),
            );
          }

          if (lotSnap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  lotSnap.error.toString(),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final doc = lotSnap.data;
          if (doc == null || !doc.exists || doc.data() == null) {
            return Center(
              child: Text(_isArabic ? 'العقار غير موجود' : 'Lot not found'),
            );
          }

          final d = doc.data()!;
          final title = d['title']?.toString() ?? '';
          final end = _readEndsAt(d);
          if (end == null) {
            return Center(
              child: Text(_isArabic ? 'بيانات المزاد غير مكتملة' : 'Invalid lot data'),
            );
          }

          final auctionId =
              widget.auctionId?.trim().isNotEmpty == true
                  ? widget.auctionId!
                  : d['auctionId']?.toString() ?? '';

          final ended = _isLotEnded(d, end);
          final high = _currentHighBid(d);
          final start = _readDouble(d['startingPrice']);
          final inc = _readDouble(d['minIncrement']);
          final bidCount = _readBidCount(d);
          final bidderId = _currentHighBidderId(d);
          final uid = FirebaseAuth.instance.currentUser?.uid;
          final isLeading = uid != null && uid == bidderId;
          final images = _imageUrls(d);
          final minNext = _minimumNextBid(d);

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _onLotSnapshot(d);
            _syncBidFieldToMinimum(d);
          });

          final urgent = !ended &&
              end.difference(_clockNow) <= const Duration(minutes: 2);
          final subMinute = !ended &&
              end.difference(_clockNow) > Duration.zero &&
              end.difference(_clockNow) < const Duration(minutes: 1);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListenableBuilder(
                listenable: AuctionTimeService.instance.reliableTime,
                builder: (context, _) {
                  if (AuctionTimeService.instance.reliableTime.value) {
                    return const SizedBox.shrink();
                  }
                  return _AuctionDetailsClockStrip(isArabic: _isArabic);
                },
              ),
              if (_outbidBannerVisible)
                _AuctionDetailsTopBanner(
                  background: Colors.red.shade800,
                  foreground: Colors.white,
                  message: _isArabic ? 'تم تجاوزك' : 'You have been outbid',
                  onDismiss: _dismissOutbidBanner,
                ),
              if (_newBidBannerVisible)
                _AuctionDetailsTopBanner(
                  background: Colors.deepOrange.shade800,
                  foreground: Colors.white,
                  message: _isArabic ? '🔥 مزايدة جديدة!' : '🔥 New bid!',
                  onDismiss: _dismissNewBidBanner,
                ),
              if ((d['status']?.toString() ?? '') == 'pending_admin_review')
                Material(
                  color: Colors.indigo.shade50,
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.hourglass_top_rounded,
                            color: Colors.indigo.shade800),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _isArabic
                                ? '⏳ بانتظار اعتماد الإدارة'
                                : '⏳ Pending admin and seller approval',
                            style: TextStyle(
                              color: Colors.indigo.shade900,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if ((d['status']?.toString() ?? '') == 'rejected')
                AuctionLotRejectionStrip(
                  rejectionReason: d['rejectionReason']?.toString(),
                ),
              Expanded(
                child: CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: _GalleryHeader(
                        images: images,
                        pageController: _galleryController,
                        galleryIndex: _galleryIndex,
                        onPageChanged: (i) => setState(() => _galleryIndex = i),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (title.isNotEmpty)
                              Text(
                                title,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.navy,
                                  height: 1.25,
                                ),
                              ),
                            if (title.isNotEmpty) const SizedBox(height: 16),
                            _PriceCard(
                              currentLabel: _isArabic ? 'أعلى مزايدة حالياً' : 'CURRENT BID',
                              currentValue: high > 0 ? _money(high) : _money(start),
                              startingLabel: _isArabic ? 'السعر الافتتاحي' : 'Starting',
                              startingValue: _money(start),
                              incrementLabel:
                                  _isArabic ? 'الحد الأدنى للزيادة' : 'Min increment',
                              incrementValue: _money(inc),
                              bidCount: bidCount,
                              bidCountLabel: _isArabic ? 'مزايدات' : 'bids',
                            ),
                            const SizedBox(height: 16),
                            _CountdownCard(
                              ended: ended,
                              end: end,
                              now: _clockNow,
                              urgent: urgent,
                              subMinuteUrgency: subMinute,
                              isArabic: _isArabic,
                            ),
                            if (isLeading && !ended) ...[
                              const SizedBox(height: 12),
                              _LeadingBanner(isArabic: _isArabic),
                            ],
                            const SizedBox(height: 20),
                            Text(
                              _isArabic ? 'آخر المزايدات' : 'Recent bids',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.navy,
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _RecentBidsBlock(
                        query: _recentBidsQuery,
                        formatMoney: _money,
                        anonymize: _anonymizeUid,
                        isArabic: _isArabic,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(height: 200 + bottomInset),
                    ),
                  ],
                ),
              ),
              _BottomBidBar(
                minNext: minNext,
                minIncrement: inc,
                ended: ended,
                isLeading: isLeading,
                placing: _placingBid,
                auctionIdReady: auctionId.isNotEmpty,
                controller: _bidAmountController,
                onQuickAdd: (delta) => _bumpBid(delta, d),
                onSubmit: auctionId.isEmpty
                    ? null
                    : () => _placeBid(auctionId, d),
                formatMoney: _money,
                isArabic: _isArabic,
                bottomPadding: bottomInset,
                errorText: _lastBidError,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AuctionDetailsClockStrip extends StatelessWidget {
  const _AuctionDetailsClockStrip({required this.isArabic});

  final bool isArabic;

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
                isArabic
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

class _AuctionDetailsTopBanner extends StatelessWidget {
  const _AuctionDetailsTopBanner({
    required this.background,
    required this.foreground,
    required this.message,
    required this.onDismiss,
  });

  final Color background;
  final Color foreground;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: background,
      elevation: 4,
      child: InkWell(
        onTap: onDismiss,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.campaign_outlined, color: foreground.withValues(alpha: 0.9), size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, color: foreground.withValues(alpha: 0.92)),
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Gallery ---

class _GalleryHeader extends StatelessWidget {
  const _GalleryHeader({
    required this.images,
    required this.pageController,
    required this.galleryIndex,
    required this.onPageChanged,
  });

  final List<String> images;
  final PageController pageController;
  final int galleryIndex;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height * 0.34;

    if (images.isEmpty) {
      return ClipRRect(
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
        child: Container(
          height: h,
          width: double.infinity,
          color: AppColors.navy.withValues(alpha: 0.08),
          child: const Center(
            child: Icon(Icons.photo_library_outlined, size: 56, color: Colors.black38),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(20),
        bottomRight: Radius.circular(20),
      ),
      child: SizedBox(
        height: h,
        width: double.infinity,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            PageView.builder(
              controller: pageController,
              itemCount: images.length,
              onPageChanged: onPageChanged,
              itemBuilder: (context, i) {
                return CachedNetworkImage(
                  imageUrl: images[i],
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: h,
                  placeholder: (_, _) => Container(
                    color: Colors.grey.shade200,
                    child: const Center(
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.navy),
                    ),
                  ),
                  errorWidget: (_, _, _) => ColoredBox(
                    color: Colors.grey.shade300,
                    child: const Icon(Icons.broken_image_outlined, size: 48),
                  ),
                );
              },
            ),
            if (images.length > 1)
              Positioned(
                bottom: 14,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(
                    images.length,
                    (i) => AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == galleryIndex ? 18 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: i == galleryIndex
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.45),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --- Price card ---

class _PriceCard extends StatelessWidget {
  const _PriceCard({
    required this.currentLabel,
    required this.currentValue,
    required this.startingLabel,
    required this.startingValue,
    required this.incrementLabel,
    required this.incrementValue,
    required this.bidCount,
    required this.bidCountLabel,
  });

  final String currentLabel;
  final String currentValue;
  final String startingLabel;
  final String startingValue;
  final String incrementLabel;
  final String incrementValue;
  final int bidCount;
  final String bidCountLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            currentLabel.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppColors.navy.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 6),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: Text(
              currentValue,
              key: ValueKey<String>(currentValue),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                color: AppColors.navy,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '$startingLabel: $startingValue',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.trending_up_rounded, size: 18, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '• $incrementLabel: $incrementValue',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.gavel_rounded, size: 18, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(
                '$bidCount $bidCountLabel',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.navy.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- Countdown ---

class _CountdownCard extends StatelessWidget {
  const _CountdownCard({
    required this.ended,
    required this.end,
    required this.now,
    required this.urgent,
    required this.subMinuteUrgency,
    required this.isArabic,
  });

  final bool ended;
  final DateTime end;
  final DateTime now;
  final bool urgent;
  final bool subMinuteUrgency;
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    if (ended) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          isArabic ? 'انتهى المزاد' : 'Auction ended',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.navy,
          ),
        ),
      );
    }

    var left = end.difference(now);
    if (left.isNegative) left = Duration.zero;

    final h = left.inHours;
    final m = left.inMinutes.remainder(60);
    final s = left.inSeconds.remainder(60);
    final text =
        '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';

    final color = urgent ? AuctionUiColors.urgencyRed : AppColors.navy;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: urgent ? AuctionUiColors.urgencyRed.withValues(alpha: 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: urgent ? AuctionUiColors.urgencyRed.withValues(alpha: 0.35) : Colors.black12,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.timer_outlined, color: color, size: 26),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isArabic ? 'الوقت المتبقي' : 'Time remaining',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color.withValues(alpha: 0.85),
                ),
              ),
              Text(
                text,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (subMinuteUrgency) ...[
                const SizedBox(height: 8),
                Text(
                  isArabic ? '⏳ باقي أقل من دقيقة' : '⏳ Less than a minute left',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AuctionUiColors.urgencyRed,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _LeadingBanner extends StatelessWidget {
  const _LeadingBanner({required this.isArabic});

  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: AuctionUiColors.winningGreenLight.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AuctionUiColors.winningGreen.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.emoji_events_rounded, color: AuctionUiColors.winningGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isArabic ? 'أنت أعلى مزايد' : 'You are the highest bidder',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AuctionUiColors.winningGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Recent bids (`lots/{id}/bids`, orderBy `createdAt`) ---

class _RecentBidsBlock extends StatelessWidget {
  const _RecentBidsBlock({
    required this.query,
    required this.formatMoney,
    required this.anonymize,
    required this.isArabic,
  });

  final Query<Map<String, dynamic>> query;
  final String Function(double) formatMoney;
  final String Function(String?) anonymize;
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              snap.error.toString(),
              style: TextStyle(color: Colors.red.shade800, fontSize: 13),
            ),
          );
        }

        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.navy),
              ),
            ),
          );
        }

        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              isArabic ? 'لا مزايدات بعد' : 'No bids yet',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: docs.map((doc) {
              final x = doc.data();
              final amount =
                  (x['amount'] is num) ? (x['amount'] as num).toDouble() : 0.0;
              final uid = x['userId']?.toString();
              final created = x['createdAt'];
              if (created is! Timestamp) {
                return const SizedBox.shrink();
              }
              final ts = created.toDate();
              final timeStr =
                  DateFormat('HH:mm:ss', isArabic ? 'ar' : 'en').format(ts.toLocal());
              return _BidRowTile(
                amount: formatMoney(amount),
                userLabel: anonymize(uid),
                time: timeStr,
              );
            }).toList(),
          ),
        );
      },
    );
  }
}

class _BidRowTile extends StatelessWidget {
  const _BidRowTile({
    required this.amount,
    required this.userLabel,
    required this.time,
  });

  final String amount;
  final String userLabel;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  amount,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  userLabel,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          Text(
            time,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Bottom bar ---

class _BottomBidBar extends StatelessWidget {
  const _BottomBidBar({
    required this.minNext,
    required this.minIncrement,
    required this.ended,
    required this.isLeading,
    required this.placing,
    required this.auctionIdReady,
    required this.controller,
    required this.onQuickAdd,
    required this.onSubmit,
    required this.formatMoney,
    required this.isArabic,
    required this.bottomPadding,
    this.errorText,
  });

  final double minNext;
  final double minIncrement;
  final bool ended;
  final bool isLeading;
  final bool placing;
  final bool auctionIdReady;
  final TextEditingController controller;
  final void Function(double delta) onQuickAdd;
  final VoidCallback? onSubmit;
  final String Function(double) formatMoney;
  final bool isArabic;
  final double bottomPadding;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final disabled = ended || isLeading || placing || !auctionIdReady;

    return Material(
      elevation: 16,
      shadowColor: Colors.black45,
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${isArabic ? 'الحد الأدنى للمزايدة التالية' : 'Next minimum bid'}: ${formatMoney(minNext)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.navy,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: !disabled,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
                      ],
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFFF0F2F7),
                        hintText: isArabic ? 'المبلغ' : 'Amount',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _QuickChip(
                    label: '+500',
                    onTap: disabled ? null : () => onQuickAdd(500),
                  ),
                  _QuickChip(
                    label: '+1000',
                    onTap: disabled ? null : () => onQuickAdd(1000),
                  ),
                  _QuickChip(
                    label: '+5000',
                    onTap: disabled ? null : () => onQuickAdd(5000),
                  ),
                  _QuickChip(
                    label: '+${minIncrement == minIncrement.roundToDouble() ? minIncrement.round() : minIncrement}',
                    onTap: disabled ? null : () => onQuickAdd(minIncrement),
                  ),
                ],
              ),
              if (errorText != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorText!,
                  style: const TextStyle(
                    color: AuctionUiColors.urgencyRed,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: disabled ? null : onSubmit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.navy,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade400,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: placing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          isArabic ? 'زايد الآن' : 'Bid now',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      onPressed: onTap,
      backgroundColor: AppColors.navy.withValues(alpha: 0.08),
      side: BorderSide(color: AppColors.navy.withValues(alpha: 0.2)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}
