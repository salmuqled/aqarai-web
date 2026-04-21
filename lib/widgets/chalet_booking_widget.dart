// lib/widgets/chalet_booking_widget.dart
//
// Airbnb-style chalet booking UI: range calendar, confirmed blocks, price summary, [ChaletBookingService].

import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import 'package:aqarai_app/models/chalet_booking.dart';
import 'package:aqarai_app/services/chalet_booking_service.dart';
import 'package:aqarai_app/pages/booking_confirmation_page.dart';

/// Bridge object for lifting chalet booking UI state to a parent `Scaffold`
/// (e.g. `bottomNavigationBar`) without changing booking logic.
///
/// Uses [ValueNotifier]s so widgets like [BookingBar] can rebuild only the
/// subtrees that depend on nights / total / CTA state.
class ChaletBookingController {
  ChaletBookingController() {
    barCtaListenable = Listenable.merge([canBookVN, submittingVN]);
  }

  DateTime? _startDate;
  DateTime? _endDate;
  VoidCallback? _submit;

  final ValueNotifier<int> nightsVN = ValueNotifier<int>(0);
  final ValueNotifier<double> totalPriceVN = ValueNotifier<double>(0);
  final ValueNotifier<bool> canBookVN = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isProvisionalVN = ValueNotifier<bool>(false);
  final ValueNotifier<bool> submittingVN = ValueNotifier<bool>(false);

  /// Optional footer line under nights/total (e.g. blended rates). When null, [BookingBar] uses per-night × nights.
  final ValueNotifier<String?> barBreakdownLineVN = ValueNotifier<String?>(null);

  /// Book CTA (enabled + loading): use with [ListenableBuilder].
  late final Listenable barCtaListenable;

  DateTime? get startDate => _startDate;
  DateTime? get endDate => _endDate;
  int get nights => nightsVN.value;
  double get totalPrice => totalPriceVN.value;
  bool get canBook => canBookVN.value;
  bool get isProvisional => isProvisionalVN.value;
  bool get submitting => submittingVN.value;

  void _update({
    required DateTime? startDate,
    required DateTime? endDate,
    required int nights,
    required double totalPrice,
    required bool canBook,
    required bool isProvisional,
    required bool submitting,
    required VoidCallback? submit,
    String? barBreakdownLine,
  }) {
    if (_sameDay(_startDate, startDate) &&
        _sameDay(_endDate, endDate) &&
        nightsVN.value == nights &&
        totalPriceVN.value == totalPrice &&
        canBookVN.value == canBook &&
        isProvisionalVN.value == isProvisional &&
        submittingVN.value == submitting &&
        identical(_submit, submit) &&
        barBreakdownLineVN.value == barBreakdownLine) {
      return;
    }

    if (!_sameDay(_startDate, startDate)) _startDate = startDate;
    if (!_sameDay(_endDate, endDate)) _endDate = endDate;

    if (nightsVN.value != nights) nightsVN.value = nights;
    if (totalPriceVN.value != totalPrice) totalPriceVN.value = totalPrice;
    if (canBookVN.value != canBook) canBookVN.value = canBook;
    if (isProvisionalVN.value != isProvisional) {
      isProvisionalVN.value = isProvisional;
    }
    if (submittingVN.value != submitting) submittingVN.value = submitting;
    if (!identical(_submit, submit)) _submit = submit;
    if (barBreakdownLineVN.value != barBreakdownLine) {
      barBreakdownLineVN.value = barBreakdownLine;
    }
  }

  static bool _sameDay(DateTime? a, DateTime? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  void submit() => _submit?.call();

  /// Clears selection and bar state when switching to another property (same [State] instance).
  void reset() {
    _startDate = null;
    _endDate = null;
    _submit = null;
    if (nightsVN.value != 0) nightsVN.value = 0;
    if (totalPriceVN.value != 0.0) totalPriceVN.value = 0.0;
    if (canBookVN.value) canBookVN.value = false;
    if (isProvisionalVN.value) isProvisionalVN.value = false;
    if (submittingVN.value) submittingVN.value = false;
    if (barBreakdownLineVN.value != null) barBreakdownLineVN.value = null;
  }

  void dispose() {
    nightsVN.dispose();
    totalPriceVN.dispose();
    canBookVN.dispose();
    isProvisionalVN.dispose();
    submittingVN.dispose();
    barBreakdownLineVN.dispose();
  }
}

bool _nightOverlapsBooked(DateTime day, ChaletBookedRange b) {
  final s = DateTime(day.year, day.month, day.day);
  final e = s.add(const Duration(days: 1));
  return s.isBefore(b.end) && e.isAfter(b.start);
}

bool _isBookedNightForRanges(DateTime day, List<ChaletBookedRange> ranges) {
  final d = DateTime(day.year, day.month, day.day);
  for (final b in ranges) {
    if (_nightOverlapsBooked(d, b)) return true;
  }
  return false;
}

/// True if at least one bookable night exists in the calendar horizon (UX empty state).
const String _kMsgDatesUnavailableAr = 'هذه التواريخ غير متاحة';
const String _kMsgDatesUnavailableEn = 'These dates are not available';

const String _kMsgSingleDateUnavailableAr = 'هذا التاريخ غير متاح';
const String _kMsgSingleDateUnavailableEn = 'This date is not available';

String _minStayMessage(int minNights, bool isAr) {
  final n = math.max(1, minNights);
  if (!isAr) {
    return n == 1
        ? 'Minimum stay is 1 night'
        : 'Minimum stay is $n nights';
  }
  if (n == 1) return 'الحد الأدنى للحجز ليلة واحدة';
  if (n == 2) return 'الحد الأدنى للحجز يومين';
  return 'الحد الأدنى للحجز $n ليالي';
}

bool chaletHorizonHasAvailableDay(
  List<ChaletBookedRange> bookedRanges,
  DateTime today,
) {
  final t = DateTime(today.year, today.month, today.day);
  var d = t;
  final limit = t.add(const Duration(days: 500));
  while (!d.isAfter(limit)) {
    final unavailable =
        d.isBefore(t) || _isBookedNightForRanges(d, bookedRanges);
    if (!unavailable) return true;
    d = d.add(const Duration(days: 1));
  }
  return false;
}

/// Peak nights default: Thursday–Saturday (ISO weekday Mon=1 … Sun=7).
const List<int> kChaletDefaultPeakWeekdays = <int>[
  DateTime.thursday,
  DateTime.friday,
  DateTime.saturday,
];

/// Bookable calendar days from [today] through [today + horizonDays] (inclusive).
int chaletCountAvailableDaysInHorizon(
  List<ChaletBookedRange> bookedRanges,
  DateTime today, {
  int horizonDays = 500,
}) {
  final t = DateTime(today.year, today.month, today.day);
  final limit = t.add(Duration(days: horizonDays));
  var c = 0;
  var d = t;
  while (!d.isAfter(limit)) {
    if (!_isBookedNightForRanges(d, bookedRanges)) c++;
    d = d.add(const Duration(days: 1));
  }
  return c;
}

/// Premium booking card for chalet listings. Does not change backend behavior.
class ChaletBookingWidget extends StatelessWidget {
  const ChaletBookingWidget({
    super.key,
    required this.propertyId,
    required this.pricePerNight,
    required this.propertyTitle,
    required this.imageUrl,
    this.currencyCode = 'KWD',
    this.controller,
    this.useExternalBookingBar = false,
    this.minNights = 1,
    this.weekendPricePerNight,
    this.peakNightWeekdays,
    /// When true, hides the title/price header so the parent (e.g. property details) supplies hierarchy.
    this.compactLayoutForPropertyDetails = false,
    /// When false, blocks client booking actions (non-public listing); server also enforces.
    this.allowPublicBooking = true,
    /// Pre-selected check-in (calendar day). Paired with [initialEndDate].
    /// Uses check-out-exclusive semantics to match [property_list.dart]
    /// (`nights = initialEndDate.difference(initialStartDate).inDays`).
    this.initialStartDate,
    /// Pre-selected check-out (exclusive). Ignored unless both initial dates
    /// are provided, in the future, and span at least [minNights] nights.
    this.initialEndDate,
  });

  final String propertyId;
  final double pricePerNight;
  final String propertyTitle;
  final String imageUrl;
  final String currencyCode;
  final ChaletBookingController? controller;

  /// When true, the booking bar is expected to be rendered by a parent `Scaffold`
  /// (e.g. `bottomNavigationBar`), and the widget will not render its internal bar.
  final bool useExternalBookingBar;

  /// Minimum number of nights for a valid stay (UI validation only; server rules unchanged).
  final int minNights;

  /// Optional higher nightly rate for [peakNightWeekdays] (also read server-side from `properties`).
  final double? weekendPricePerNight;

  /// ISO weekdays (Mon=1 … Sun=7). Defaults to Thu–Sat when null/empty.
  final List<int>? peakNightWeekdays;

  /// Hides duplicate title + per-night price block when embedded in a parent card.
  final bool compactLayoutForPropertyDetails;

  /// Guest booking allowed only when the listing is publicly discoverable.
  final bool allowPublicBooking;

  /// Optional pre-selected check-in. Only applied once on the first
  /// successful calendar render when paired with a valid [initialEndDate].
  final DateTime? initialStartDate;

  /// Optional pre-selected check-out (exclusive). See [initialStartDate].
  final DateTime? initialEndDate;

  static List<ChaletBookedRange> _blockedRangesFromSnapshot(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final out = <ChaletBookedRange>[];
    for (final d in docs) {
      final data = d.data();
      final tsA = data['startDate'];
      final tsB = data['endDate'];
      if (tsA is! Timestamp || tsB is! Timestamp) continue;
      out.add(ChaletBookedRange(start: tsA.toDate(), end: tsB.toDate()));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (pricePerNight <= 0) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');

    final peakRate =
        (weekendPricePerNight != null && weekendPricePerNight! > pricePerNight)
            ? weekendPricePerNight!
            : pricePerNight;
    final peakDartWeekdays = (peakNightWeekdays != null &&
            peakNightWeekdays!.isNotEmpty)
        ? peakNightWeekdays!
              .where((e) => e >= DateTime.monday && e <= DateTime.sunday)
              .toList()
        : kChaletDefaultPeakWeekdays;
    final peakLine = peakRate > pricePerNight
        ? (isAr ? 'ذروة: ${fmt.format(peakRate)} $currencyCode / ليلة'
              : 'Peak: ${fmt.format(peakRate)} $currencyCode / night')
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = math.min(constraints.maxWidth, 520.0);
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: _BookingChrome(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!compactLayoutForPropertyDetails) ...[
                    Row(
                      children: [
                        Icon(
                          Icons.calendar_month_rounded,
                          color: cs.primary,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            isAr ? 'احجز الشاليه' : 'Book this chalet',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      isAr
                          ? 'اختر تاريخ الوصول والمغادرة'
                          : 'Select check-in and check-out dates',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.hintColor,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _PriceNightHeader(
                      formattedPrice: fmt.format(pricePerNight),
                      currency: currencyCode,
                      isAr: isAr,
                      subtitle: peakLine,
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    height: math.min(
                      MediaQuery.sizeOf(context).height * 0.62,
                      580,
                    ),
                    child: _ChaletBookingFirestoreGate(
                      propertyId: propertyId,
                      propertyTitle: propertyTitle,
                      imageUrl: imageUrl,
                      weekdayPrice: pricePerNight,
                      peakPrice: peakRate,
                      peakDartWeekdays: peakDartWeekdays,
                      currencyCode: currencyCode,
                      controller: controller,
                      useExternalBookingBar: useExternalBookingBar,
                      minNights: minNights,
                      errorTextStyle: TextStyle(color: cs.error),
                      isAr: isAr,
                      allowPublicBooking: allowPublicBooking,
                      initialStartDate: initialStartDate,
                      initialEndDate: initialEndDate,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Holds Firestore streams and avoids flashing the calendar on reconnect by
/// tracking first successful snapshots per property.
class _ChaletBookingFirestoreGate extends StatefulWidget {
  const _ChaletBookingFirestoreGate({
    required this.propertyId,
    required this.propertyTitle,
    required this.imageUrl,
    required this.weekdayPrice,
    required this.peakPrice,
    required this.peakDartWeekdays,
    required this.currencyCode,
    required this.controller,
    required this.useExternalBookingBar,
    required this.minNights,
    required this.errorTextStyle,
    required this.isAr,
    required this.allowPublicBooking,
    this.initialStartDate,
    this.initialEndDate,
  });

  final String propertyId;
  final String propertyTitle;
  final String imageUrl;
  final double weekdayPrice;
  final double peakPrice;
  final List<int> peakDartWeekdays;
  final String currencyCode;
  final ChaletBookingController? controller;
  final bool useExternalBookingBar;
  final int minNights;
  final TextStyle errorTextStyle;
  final bool isAr;
  final bool allowPublicBooking;
  final DateTime? initialStartDate;
  final DateTime? initialEndDate;

  @override
  State<_ChaletBookingFirestoreGate> createState() =>
      _ChaletBookingFirestoreGateState();
}

class _ChaletBookingFirestoreGateState extends State<_ChaletBookingFirestoreGate> {
  bool _sawBlockedSnapshot = false;
  bool _serverBusyLoaded = false;
  List<ChaletBookedRange> _serverBookingRanges = [];
  Timer? _busyPollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshServerBusyRanges());
    _busyPollTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => _refreshServerBusyRanges(),
    );
  }

  @override
  void dispose() {
    _busyPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshServerBusyRanges() async {
    final ranges = await ChaletBookingService.getChaletBusyDateRanges(
      propertyId: widget.propertyId,
    );
    if (!mounted) return;
    setState(() {
      _serverBusyLoaded = true;
      if (ranges != null) {
        _serverBookingRanges = ranges;
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ChaletBookingFirestoreGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.propertyId != widget.propertyId) {
      _sawBlockedSnapshot = false;
      _serverBusyLoaded = false;
      _serverBookingRanges = [];
      _refreshServerBusyRanges();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('blocked_dates')
          .where('propertyId', isEqualTo: widget.propertyId)
          .snapshots(),
      builder: (context, blockSnap) {
        if (blockSnap.hasData) _sawBlockedSnapshot = true;

        final waitingInitial =
            !_serverBusyLoaded ||
                (!_sawBlockedSnapshot &&
                    blockSnap.connectionState == ConnectionState.waiting);

        late final Widget body;
        if (blockSnap.hasError) {
          body = Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              blockSnap.error.toString(),
              style: widget.errorTextStyle,
            ),
          );
        } else if (waitingInitial) {
          body = const _CalendarSkeleton(key: ValueKey<String>('cal-skel'));
        } else {
          final bookingRanges = _serverBookingRanges;
          final blockedRanges =
              ChaletBookingWidget._blockedRangesFromSnapshot(
            blockSnap.data?.docs ?? [],
          );
          final ranges = <ChaletBookedRange>[
            ...bookingRanges,
            ...blockedRanges,
          ];
          final today = DateTime(
            DateTime.now().year,
            DateTime.now().month,
            DateTime.now().day,
          );
          if (!chaletHorizonHasAvailableDay(ranges, today)) {
            body = _NoAvailabilityBody(
              isAr: widget.isAr,
              pricePerNight: widget.weekdayPrice,
              currencyCode: widget.currencyCode,
              showInternalBar: !widget.useExternalBookingBar,
            );
          } else {
            body = _ChaletBookingBody(
              propertyId: widget.propertyId,
              propertyTitle: widget.propertyTitle,
              imageUrl: widget.imageUrl,
              weekdayPrice: widget.weekdayPrice,
              peakPrice: widget.peakPrice,
              peakDartWeekdays: widget.peakDartWeekdays,
              currencyCode: widget.currencyCode,
              bookedRanges: ranges,
              controller: widget.controller,
              showInternalBar: !widget.useExternalBookingBar,
              minNights: math.max(1, widget.minNights),
              showFullyAvailableBanner: bookingRanges.isEmpty,
              allowPublicBooking: widget.allowPublicBooking,
              initialStartDate: widget.initialStartDate,
              initialEndDate: widget.initialEndDate,
            );
          }
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) {
            return FadeTransition(opacity: anim, child: child);
          },
          child: KeyedSubtree(
            key: ValueKey<String>(
              blockSnap.hasError
                  ? 'err'
                  : waitingInitial
                      ? 'skel'
                      : 'cal-${widget.propertyId}',
            ),
            child: body,
          ),
        );
      },
    );
  }
}

/// Always visible: "25 KWD / night" (localized).
class _PriceNightHeader extends StatelessWidget {
  const _PriceNightHeader({
    required this.formattedPrice,
    required this.currency,
    required this.isAr,
    this.subtitle,
  });

  final String formattedPrice;
  final String currency;
  final bool isAr;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final nightLabel = isAr ? 'ليلة' : 'night';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.primary.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sell_outlined, size: 22, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$formattedPrice $currency / $nightLabel',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cs.onPrimaryContainer,
                    letterSpacing: -0.2,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: cs.onPrimaryContainer.withValues(alpha: 0.88),
                      fontWeight: FontWeight.w600,
                      height: 1.25,
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

/// Shimmer-like placeholder until first Firestore snapshot arrives.
class _CalendarSkeleton extends StatefulWidget {
  const _CalendarSkeleton({super.key});

  @override
  State<_CalendarSkeleton> createState() => _CalendarSkeletonState();
}

class _CalendarSkeletonState extends State<_CalendarSkeleton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_pulse.value);
        final shimmer = -1.15 + 2.3 * t;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest.withValues(
                          alpha: 0.55,
                        ),
                      ),
                    ),
                    ShaderMask(
                      blendMode: BlendMode.srcATop,
                      shaderCallback: (bounds) {
                        return LinearGradient(
                          begin: Alignment(shimmer - 0.5, 0),
                          end: Alignment(shimmer + 0.5, 0),
                          colors: [
                            Colors.grey.withValues(alpha: 0.08),
                            Colors.grey.withValues(alpha: 0.22),
                            Colors.grey.withValues(alpha: 0.08),
                          ],
                          stops: const [0.35, 0.5, 0.65],
                        ).createShader(bounds);
                      },
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.onSurface.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: cs.primary.withValues(alpha: 0.65),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            Localizations.localeOf(context).languageCode == 'ar'
                                ? 'جاري تحميل التوافر…'
                                : 'Loading availability…',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: cs.onSurface.withValues(alpha: 0.55),
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _SummarySkeletonPlaceholder(height: 72),
          ],
        );
      },
    );
  }
}

class _SummarySkeletonPlaceholder extends StatelessWidget {
  const _SummarySkeletonPlaceholder({this.height = 120});

  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border.all(color: cs.outline.withValues(alpha: 0.12)),
      ),
    );
  }
}

/// Sticky footer: live nightly rate, nights, total, and book action (always visible in booking block).
class _StickyBookingBar extends StatelessWidget {
  const _StickyBookingBar({
    required this.isAr,
    required this.nights,
    required this.totalLabel,
    this.breakdownLabel,
    this.omitBookButtonTotal = false,
    required this.isProvisional,
    required this.canBook,
    required this.submitting,
    required this.bookButtonPressed,
    required this.onPointerDown,
    required this.onPointerUp,
    required this.onPointerCancel,
    required this.onBook,
  });

  final bool isAr;
  final int nights;
  final String totalLabel;
  final String? breakdownLabel;
  /// When true and [nights] ≥ 1, book CTA omits the trailing price (total not from server yet).
  final bool omitBookButtonTotal;
  final bool isProvisional;
  final bool canBook;
  final bool submitting;
  final bool bookButtonPressed;
  final void Function(PointerDownEvent)? onPointerDown;
  final void Function(PointerUpEvent)? onPointerUp;
  final void Function(PointerCancelEvent)? onPointerCancel;
  final VoidCallback? onBook;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurface.withValues(alpha: 0.55),
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
    );
    final valueStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.2,
    );

    return Material(
      elevation: 14,
      shadowColor: cs.shadow.withValues(alpha: 0.22),
      color: cs.surfaceContainerLowest,
      surfaceTintColor: cs.surfaceTint,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.14)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isAr ? 'عدد الأيام' : 'Nights',
                          style: labelStyle,
                        ),
                        const SizedBox(height: 4),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 320),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, anim) {
                            return FadeTransition(
                              opacity: anim,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.12),
                                  end: Offset.zero,
                                ).animate(anim),
                                child: child,
                              ),
                            );
                          },
                          child: Text(
                            '$nights',
                            key: ValueKey<int>(nights),
                            style: valueStyle?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          isAr ? 'السعر الإجمالي' : 'Total price',
                          style: labelStyle,
                          textAlign: TextAlign.end,
                        ),
                        const SizedBox(height: 4),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 320),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, anim) {
                            return FadeTransition(
                              opacity: anim,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.12),
                                  end: Offset.zero,
                                ).animate(anim),
                                child: child,
                              ),
                            );
                          },
                          child: Text(
                            totalLabel,
                            key: ValueKey<String>(totalLabel),
                            style: valueStyle?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            textAlign: TextAlign.end,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (breakdownLabel != null && breakdownLabel!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  breakdownLabel!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.62),
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (isProvisional) ...[
                const SizedBox(height: 8),
                AnimatedOpacity(
                  opacity: 1,
                  duration: const Duration(milliseconds: 260),
                  child: Text(
                    isAr
                        ? 'معاينة — اضغط تاريخ المغادرة لإنهاء الاختيار'
                        : 'Preview — tap check-out to confirm your stay',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: cs.primary.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Listener(
                onPointerDown: onPointerDown,
                onPointerUp: onPointerUp,
                onPointerCancel: onPointerCancel,
                child: AnimatedScale(
                  scale: bookButtonPressed ? 0.985 : 1.0,
                  duration: const Duration(milliseconds: 100),
                  curve: Curves.easeOutCubic,
                  child: FilledButton(
                    onPressed: canBook ? onBook : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: canBook ? 2.5 : 0,
                    ),
                    child: submitting
                        ? SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: cs.onPrimary,
                            ),
                          )
                        : Text(
                            nights < 1
                                ? (isAr
                                    ? 'اختر التواريخ للحجز'
                                    : 'Select dates to book')
                                : (omitBookButtonTotal
                                    ? (isAr ? 'احجز الآن' : 'Book now')
                                    : (isAr
                                        ? 'احجز الآن - $totalLabel'
                                        : 'Book now - $totalLabel')),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
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

class _NoAvailabilityBody extends StatelessWidget {
  const _NoAvailabilityBody({
    required this.isAr,
    required this.pricePerNight,
    required this.currencyCode,
    required this.showInternalBar,
  });

  final bool isAr;
  final double pricePerNight;
  final String currencyCode;
  final bool showInternalBar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 8),
                  AnimatedOpacity(
                    opacity: 1,
                    duration: const Duration(milliseconds: 450),
                    curve: Curves.easeOut,
                    child: Icon(
                      Icons.event_busy_rounded,
                      size: 52,
                      color: cs.primary.withValues(alpha: 0.42),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'لا توجد مواعيد متاحة حالياً',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'No availability at the moment',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
        if (showInternalBar)
          _StickyBookingBar(
            isAr: isAr,
            nights: 0,
            totalLabel: '${fmt.format(0)} $currencyCode',
            breakdownLabel: null,
            isProvisional: false,
            canBook: false,
            submitting: false,
            bookButtonPressed: false,
            onPointerDown: null,
            onPointerUp: null,
            onPointerCancel: null,
            onBook: null,
          ),
      ],
    );
  }
}

class _ChaletBookingBody extends StatefulWidget {
  const _ChaletBookingBody({
    required this.propertyId,
    required this.propertyTitle,
    required this.imageUrl,
    required this.weekdayPrice,
    required this.peakPrice,
    required this.peakDartWeekdays,
    required this.currencyCode,
    required this.bookedRanges,
    required this.showInternalBar,
    required this.minNights,
    required this.showFullyAvailableBanner,
    this.controller,
    required this.allowPublicBooking,
    this.initialStartDate,
    this.initialEndDate,
  });

  final String propertyId;
  final String propertyTitle;
  final String imageUrl;
  final double weekdayPrice;
  final double peakPrice;
  final List<int> peakDartWeekdays;
  final String currencyCode;
  final List<ChaletBookedRange> bookedRanges;
  final bool showInternalBar;
  final int minNights;
  final bool showFullyAvailableBanner;
  final ChaletBookingController? controller;
  final bool allowPublicBooking;
  final DateTime? initialStartDate;
  final DateTime? initialEndDate;

  @override
  State<_ChaletBookingBody> createState() => _ChaletBookingBodyState();
}

class _ChaletBookingBodyState extends State<_ChaletBookingBody> {
  static const int _urgencyMaxAvailableDays = 10;

  DateTime _focusedDay = DateTime.now();
  DateTime? _rangeStart;
  DateTime? _rangeEnd;
  bool _submitting = false;
  bool _bookButtonPressed = false;
  String? _selectionHint;
  bool _selectionHintIsBookedConflict = false;
  bool _selectionHintIsMinStay = false;
  bool _selectionHintIsUnavailableDateTap = false;

  @override
  void initState() {
    super.initState();
    // Pre-seed the range from caller-provided dates (e.g. list-page filter)
    // so the booking CTA is available on first paint without re-selection.
    // Guarded to avoid leaking invalid / stale ranges into the controller.
    final seeded = _seedFromInitial(
      widget.initialStartDate,
      widget.initialEndDate,
    );
    if (seeded != null) {
      _rangeStart = seeded.$1;
      _rangeEnd = seeded.$2;
      _focusedDay = seeded.$1;
    }
  }

  /// Returns `(start, endExclusive)` only when both inputs are non-null,
  /// today-or-future, strictly ordered, meet [widget.minNights], and do not
  /// overlap any [widget.bookedRanges]. Otherwise returns `null` so the
  /// caller falls back to the default unseeded flow. Uses the same
  /// check-out-exclusive semantics as [property_list.dart].
  (DateTime, DateTime)? _seedFromInitial(
    DateTime? start,
    DateTime? end,
  ) {
    if (start == null || end == null) return null;
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    final todayOnly = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    if (s.isBefore(todayOnly)) return null;
    if (!e.isAfter(s)) return null;
    final nights = e.difference(s).inDays;
    if (nights < math.max(1, widget.minNights)) return null;
    for (final b in widget.bookedRanges) {
      if (s.isBefore(b.end) && e.isAfter(b.start)) return null;
    }
    return (s, e);
  }

  @override
  void didUpdateWidget(covariant _ChaletBookingBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.propertyId != widget.propertyId) {
      widget.controller?.reset();
      _focusedDay = DateTime.now();
      _rangeStart = null;
      _rangeEnd = null;
      _submitting = false;
      _bookButtonPressed = false;
      _selectionHint = null;
      _selectionHintIsBookedConflict = false;
      _selectionHintIsMinStay = false;
      _selectionHintIsUnavailableDateTap = false;
    }
  }

  bool get _isAr => Localizations.localeOf(context).languageCode == 'ar';

  String get _msgDatesUnavailable =>
      _isAr ? _kMsgDatesUnavailableAr : _kMsgDatesUnavailableEn;

  String get _msgSingleDateUnavailable =>
      _isAr ? _kMsgSingleDateUnavailableAr : _kMsgSingleDateUnavailableEn;

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  DateTime get _today => _dateOnly(DateTime.now());

  bool _nightOverlapsBooking(DateTime day, ChaletBookedRange b) {
    final s = _dateOnly(day);
    final e = s.add(const Duration(days: 1));
    return s.isBefore(b.end) && e.isAfter(b.start);
  }

  bool _isBookedNight(DateTime day) {
    final d = _dateOnly(day);
    for (final b in widget.bookedRanges) {
      if (_nightOverlapsBooking(d, b)) return true;
    }
    return false;
  }

  bool _isPastDay(DateTime day) => _dateOnly(day).isBefore(_today);

  bool _isDayUnavailable(DateTime day) =>
      _isPastDay(day) || _isBookedNight(day);

  bool _rangeConflicts(DateTime checkIn, DateTime checkOutExclusive) {
    for (final b in widget.bookedRanges) {
      if (checkIn.isBefore(b.end) && checkOutExclusive.isAfter(b.start)) {
        return true;
      }
    }
    return false;
  }

  bool _stayHasBlockedNight(DateTime checkIn, DateTime checkOutExclusive) {
    for (
      var d = checkIn;
      d.isBefore(checkOutExclusive);
      d = d.add(const Duration(days: 1))
    ) {
      if (_isDayUnavailable(d)) return true;
    }
    return false;
  }

  /// True if the stay shares any night with booked/blocked intervals (no partial straddling).
  bool _stayOverlapsReserved(
    DateTime checkIn,
    DateTime checkOutExclusive,
  ) {
    return _rangeConflicts(checkIn, checkOutExclusive) ||
        _stayHasBlockedNight(checkIn, checkOutExclusive);
  }

  (DateTime checkIn, DateTime checkOutExclusive)? _computeStayBounds() {
    if (_rangeStart == null || _rangeEnd == null) return null;
    var a = _dateOnly(_rangeStart!);
    var b = _dateOnly(_rangeEnd!);
    if (a.isAfter(b)) {
      final t = a;
      a = b;
      b = t;
    }
    final checkIn = a;
    final checkOutExclusive = b.add(const Duration(days: 1));
    return (checkIn, checkOutExclusive);
  }

  int get _nights {
    final bounds = _computeStayBounds();
    if (bounds == null) return 0;
    final days = bounds.$2.difference(bounds.$1).inDays;
    return math.max(0, days);
  }

  /// In-range preview while check-in is set and user moves focus / selects check-out (UX only).
  (DateTime checkIn, DateTime checkOutExclusive)? get _provisionalBounds {
    if (_rangeStart == null || _rangeEnd != null) return null;
    final s = _dateOnly(_rangeStart!);
    final f = _dateOnly(_focusedDay);
    if (!f.isAfter(s)) return null;
    final checkIn = s;
    final checkOutExclusive = f.add(const Duration(days: 1));
    if (_stayOverlapsReserved(checkIn, checkOutExclusive)) return null;
    final provNights = checkOutExclusive.difference(checkIn).inDays;
    if (provNights < widget.minNights) return null;
    return (checkIn, checkOutExclusive);
  }

  (DateTime checkIn, DateTime checkOutExclusive)? get _liveStayBounds =>
      _computeStayBounds() ?? _provisionalBounds;

  int get _liveNights {
    final b = _liveStayBounds;
    if (b == null) return 0;
    return math.max(0, b.$2.difference(b.$1).inDays);
  }

  void _resetQuotedTotalOnController() {
    widget.controller?.totalPriceVN.value = 0.0;
  }

  bool get _isProvisionalPricing =>
      _computeStayBounds() == null && _provisionalBounds != null;

  /// Book button enabled only with full range and no conflict.
  bool get _isValidSelection {
    if (_rangeStart == null || _rangeEnd == null) return false;
    final bounds = _computeStayBounds();
    if (bounds == null || _nights < 1) return false;
    if (_nights < widget.minNights) return false;
    if (_stayOverlapsReserved(bounds.$1, bounds.$2)) return false;
    return true;
  }

  void _submitPlaceholder() {
    if (!_isValidSelection) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        content: Text(
          _isAr
              ? 'تم اختيار التواريخ — الإجمالي يُعرض بعد إنشاء الحجز'
              : 'Dates selected — total is shown after booking is created',
        ),
      ),
    );
  }

  Future<void> _payNowFlow() async {
    if (!_isValidSelection || _submitting) return;
    if (!widget.allowPublicBooking) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          content: Text(
            _isAr
                ? 'هذا العقار غير متاح للحجز حالياً'
                : 'This property is not available for booking right now.',
          ),
        ),
      );
      return;
    }
    final bounds = _computeStayBounds();
    if (bounds == null || _nights < 1) return;

    setState(() => _submitting = true);
    try {
      final created = await ChaletBookingService.createBooking(
        propertyId: widget.propertyId,
        startDate: bounds.$1,
        endDate: bounds.$2,
      );
      if (!mounted) return;
      if (!created.ok || (created.bookingId ?? '').isEmpty) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              created.errorMessage ??
                  (_isAr ? 'تعذر إنشاء الحجز' : 'Could not create booking'),
            ),
          ),
        );
        return;
      }

      final serverTotal = created.totalPrice;
      final serverDays = created.daysCount;
      final serverPpn = created.pricePerNight;
      if (serverTotal == null || serverDays == null || serverPpn == null) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              _isAr ? 'استجابة غير صالحة من الخادم' : 'Invalid server response',
            ),
          ),
        );
        return;
      }

      widget.controller?.totalPriceVN.value = serverTotal;

      final bookingId = created.bookingId!;
      final paid = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => BookingConfirmationPage(
            bookingId: bookingId,
            propertyId: widget.propertyId,
            propertyTitle: widget.propertyTitle,
            imageUrl: widget.imageUrl,
            startDate: bounds.$1,
            endDate: bounds.$2,
            nights: serverDays,
            pricePerNight: serverPpn,
            totalPrice: serverTotal,
          ),
        ),
      );
      if (!mounted) return;

      setState(() {
        _submitting = false;
        if (paid == true) {
          _rangeStart = null;
          _rangeEnd = null;
          _resetQuotedTotalOnController();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(_isAr ? 'حدث خطأ غير متوقع' : 'Unexpected error'),
        ),
      );
    }
  }

  void _showDatesUnavailableFeedback() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            Icon(Icons.event_busy_rounded, color: Colors.red.shade100),
            const SizedBox(width: 12),
            Expanded(child: Text(_msgDatesUnavailable)),
          ],
        ),
        backgroundColor: Colors.red.shade900.withValues(alpha: 0.92),
      ),
    );
  }

  void _showMinStayFeedback() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            Icon(Icons.schedule_rounded, color: Colors.amber.shade50),
            const SizedBox(width: 12),
            Expanded(
              child: Text(_minStayMessage(widget.minNights, _isAr)),
            ),
          ],
        ),
        backgroundColor: Colors.brown.shade800.withValues(alpha: 0.94),
      ),
    );
  }

  void _showSingleDateUnavailableFeedback() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        duration: const Duration(seconds: 2),
        content: Text(_msgSingleDateUnavailable),
        backgroundColor: Colors.grey.shade800.withValues(alpha: 0.92),
      ),
    );
  }

  void _onDisabledDayTapped(DateTime day) {
    HapticFeedback.lightImpact();
    setState(() {
      _selectionHint = _msgSingleDateUnavailable;
      _selectionHintIsBookedConflict = false;
      _selectionHintIsMinStay = false;
      _selectionHintIsUnavailableDateTap = true;
    });
    _showSingleDateUnavailableFeedback();
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    setState(() {
      _resetQuotedTotalOnController();
      _focusedDay = focusedDay;
      _selectionHint = null;
      _selectionHintIsBookedConflict = false;
      _selectionHintIsMinStay = false;
      _selectionHintIsUnavailableDateTap = false;
      final d = _dateOnly(selectedDay);

      if (_isDayUnavailable(d)) {
        _selectionHint = _msgDatesUnavailable;
        _selectionHintIsBookedConflict = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showDatesUnavailableFeedback();
        });
        return;
      }

      if (_rangeStart != null && _rangeEnd != null) {
        _rangeStart = d;
        _rangeEnd = null;
        return;
      }

      if (_rangeStart == null) {
        _rangeStart = d;
        _rangeEnd = null;
        return;
      }

      final s = _dateOnly(_rangeStart!);
      if (d.isBefore(s)) {
        _rangeStart = d;
        _rangeEnd = null;
        return;
      }

      if (isSameDay(d, s)) {
        _rangeStart = null;
        _rangeEnd = null;
        return;
      }

      final checkIn = s;
      final checkOutExclusive = d.add(const Duration(days: 1));
      if (_stayOverlapsReserved(checkIn, checkOutExclusive)) {
        _selectionHint = _msgDatesUnavailable;
        _selectionHintIsBookedConflict = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showDatesUnavailableFeedback();
        });
        return;
      }

      final nights = checkOutExclusive.difference(checkIn).inDays;
      if (nights < widget.minNights) {
        _selectionHint = _minStayMessage(widget.minNights, _isAr);
        _selectionHintIsMinStay = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showMinStayFeedback();
        });
        return;
      }

      _rangeEnd = d;
    });
  }

  Future<void> _submit() async {
    // Keep method for compatibility with older call sites, but do not touch
    // backend / payment flows yet (UI-only booking).
    _submitPlaceholder();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final locale = _isAr ? 'ar' : 'en_US';
    final fmt = NumberFormat.decimalPattern(_isAr ? 'ar' : 'en');
    final currencyLabel = _isAr ? 'د.ك' : widget.currencyCode;

    final rangeKey =
        '${_rangeStart?.toIso8601String()}_${_rangeEnd?.toIso8601String()}';

    final canBook = _isValidSelection && !_submitting;
    final availableDayCount =
        chaletCountAvailableDaysInHorizon(widget.bookedRanges, _today);
    final showUrgency = availableDayCount > 0 &&
        availableDayCount <= _urgencyMaxAvailableDays;

    final barTotal = widget.controller?.totalPriceVN.value ?? 0.0;
    final totalLabel = barTotal > 0
        ? '${fmt.format(barTotal)} $currencyLabel'
        : (_liveNights > 0 ? '—' : '${fmt.format(0)} $currencyLabel');
    final boundsLive = _liveStayBounds;
    String? datesChipLabel;
    if (boundsLive != null) {
      final lastNight = boundsLive.$2.subtract(const Duration(days: 1));
      datesChipLabel =
          '${DateFormat.yMMMd(locale).format(boundsLive.$1)} → ${DateFormat.yMMMd(locale).format(lastNight)}';
    }

    final String? breakdownLabel = (_liveNights > 0 && barTotal <= 0)
        ? (_isAr
            ? 'الإجمالي يُحسب على الخادم عند الحجز'
            : 'Total is calculated on the server when you book')
        : null;

    final String? barBreakdownLine =
        _liveNights > 0 && barTotal <= 0 ? '' : null;

    widget.controller?._update(
      startDate: boundsLive?.$1,
      endDate: boundsLive?.$2.subtract(const Duration(days: 1)),
      nights: _nights,
      totalPrice: barTotal,
      canBook: canBook,
      isProvisional: _isProvisionalPricing,
      submitting: _submitting,
      submit: canBook ? () => unawaited(_payNowFlow()) : null,
      barBreakdownLine: barBreakdownLine,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.showFullyAvailableBanner) ...[
                  Material(
                    color: cs.tertiaryContainer.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.verified_outlined,
                            color: cs.onTertiaryContainer,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _isAr ? 'متاح بالكامل' : 'Fully available',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: cs.onTertiaryContainer,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (showUrgency) ...[
                  Material(
                    color: cs.errorContainer.withValues(alpha: 0.38),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.local_fire_department_rounded,
                            color: cs.onErrorContainer,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _isAr
                                  ? 'متبقي $availableDayCount أيام فقط'
                                  : 'Only $availableDayCount days left',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: cs.onErrorContainer,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                AnimatedContainer(
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: cs.shadow.withValues(
                          alpha: _isValidSelection ? 0.14 : 0.08,
                        ),
                        blurRadius: _isValidSelection ? 20 : 14,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Material(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(18),
                    clipBehavior: Clip.antiAlias,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) {
                        final curved = CurvedAnimation(
                          parent: anim,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic,
                        );
                        return FadeTransition(
                          opacity: curved,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.024),
                              end: Offset.zero,
                            ).animate(curved),
                            child: child,
                          ),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey<String>(rangeKey),
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey<String>(rangeKey),
                          tween: Tween(begin: 0.992, end: 1.0),
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeOutCubic,
                          builder: (context, scale, child) => Transform.scale(
                            scale: scale,
                            alignment: Alignment.topCenter,
                            child: child!,
                          ),
                          child: TableCalendar<void>(
                            locale: locale,
                            firstDay: _today,
                            lastDay: _today.add(const Duration(days: 500)),
                            focusedDay: _focusedDay,
                            rangeStartDay: _rangeStart,
                            rangeEndDay: _rangeEnd,
                            rangeSelectionMode: RangeSelectionMode.disabled,
                            enabledDayPredicate: (day) =>
                                !_isDayUnavailable(day),
                            onDaySelected: _onDaySelected,
                            onDisabledDayTapped: _onDisabledDayTapped,
                            onPageChanged: (f) =>
                                setState(() => _focusedDay = f),
                            calendarStyle: CalendarStyle(
                              cellMargin: const EdgeInsets.symmetric(
                                horizontal: 3,
                                vertical: 4,
                              ),
                              todayDecoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.16),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: cs.primary.withValues(alpha: 0.45),
                                  width: 1.5,
                                ),
                              ),
                              todayTextStyle: TextStyle(
                                color: cs.primary,
                                fontWeight: FontWeight.w800,
                              ),
                              disabledTextStyle: TextStyle(
                                color: cs.onSurface.withValues(alpha: 0.32),
                              ),
                              outsideDaysVisible: false,
                              rangeHighlightColor: Colors.transparent,
                              rangeHighlightScale: 1.0,
                              rangeStartDecoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: cs.primary.withValues(alpha: 0.45),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              rangeStartTextStyle: TextStyle(
                                color: cs.onPrimary,
                                fontWeight: FontWeight.w900,
                              ),
                              rangeEndDecoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: cs.primary.withValues(alpha: 0.45),
                                    blurRadius: 10,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              rangeEndTextStyle: TextStyle(
                                color: cs.onPrimary,
                                fontWeight: FontWeight.w900,
                              ),
                              withinRangeTextStyle: TextStyle(
                                color: cs.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                              defaultDecoration: const BoxDecoration(
                                shape: BoxShape.circle,
                              ),
                              weekendTextStyle: TextStyle(color: cs.onSurface),
                            ),
                            daysOfWeekStyle: DaysOfWeekStyle(
                              weekdayStyle: TextStyle(
                                color: cs.onSurface.withValues(alpha: 0.65),
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                              weekendStyle: TextStyle(
                                color: cs.primary.withValues(alpha: 0.88),
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                            headerStyle: HeaderStyle(
                              formatButtonVisible: false,
                              titleCentered: true,
                              headerPadding: const EdgeInsets.only(bottom: 10),
                              titleTextStyle: theme.textTheme.titleSmall!
                                  .copyWith(fontWeight: FontWeight.w800),
                              leftChevronIcon: Icon(
                                Icons.chevron_left,
                                color: cs.primary,
                              ),
                              rightChevronIcon: Icon(
                                Icons.chevron_right,
                                color: cs.primary,
                              ),
                            ),
                            calendarBuilders: CalendarBuilders(
                              rangeHighlightBuilder: (context, day, inRange) {
                                if (!inRange) return null;
                                final rs = _rangeStart;
                                final re = _rangeEnd;
                                if (rs == null || re == null) return null;
                                final d = _dateOnly(day);
                                final isStart = isSameDay(d, rs);
                                final isEnd = isSameDay(d, re);
                                final cellKey = d.toIso8601String();
                                return TweenAnimationBuilder<double>(
                                  key: ValueKey<String>('rh_${rangeKey}_$cellKey'),
                                  tween: Tween(begin: 0.0, end: 1.0),
                                  duration: const Duration(milliseconds: 280),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, t, child) =>
                                      Opacity(opacity: t, child: child),
                                  child: LayoutBuilder(
                                    builder: (context, c) {
                                      final shorterSide = c.maxHeight >
                                              c.maxWidth
                                          ? c.maxWidth
                                          : c.maxHeight;
                                      final h = (shorterSide - 8.0) * 0.78;
                                      return Center(
                                        child: Container(
                                          margin:
                                              EdgeInsetsDirectional.only(
                                            start: isStart
                                                ? c.maxWidth * 0.5
                                                : 0,
                                            end: isEnd ? c.maxWidth * 0.5 : 0,
                                          ),
                                          height: h,
                                          decoration: BoxDecoration(
                                            color: cs.primary.withValues(
                                              alpha: 0.2,
                                            ),
                                            borderRadius:
                                                BorderRadiusDirectional
                                                    .horizontal(
                                              start: isStart
                                                  ? const Radius.circular(999)
                                                  : Radius.zero,
                                              end: isEnd
                                                  ? const Radius.circular(999)
                                                  : Radius.zero,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                              defaultBuilder: (context, day, focused) {
                                return _DayCell(
                                  day: day.day,
                                  textStyle: theme.textTheme.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                );
                              },
                              disabledBuilder: (context, day, focused) {
                                final unavailableText = Colors.grey.shade600;
                                return Opacity(
                                  opacity: 0.3,
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade300.withValues(
                                        alpha: 0.48,
                                      ),
                                      borderRadius: BorderRadius.circular(11),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${day.day}',
                                      style: TextStyle(
                                        color: unavailableText,
                                        fontWeight: FontWeight.w600,
                                        decoration:
                                            TextDecoration.lineThrough,
                                        decorationColor: unavailableText
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ),
                                );
                              },
                              rangeStartBuilder: (context, day, focusedDay) {
                                return TweenAnimationBuilder<double>(
                                  key: ValueKey<String>('rs_$rangeKey'),
                                  tween: Tween(begin: 0.94, end: 1.0),
                                  duration: const Duration(milliseconds: 240),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, scale, child) =>
                                      Transform.scale(
                                    scale: scale,
                                    alignment: Alignment.center,
                                    child: child,
                                  ),
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: cs.primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2.2,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: cs.primary.withValues(
                                            alpha: 0.45,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${day.day}',
                                      style: TextStyle(
                                        color: cs.onPrimary,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                );
                              },
                              rangeEndBuilder: (context, day, focusedDay) {
                                return TweenAnimationBuilder<double>(
                                  key: ValueKey<String>('re_$rangeKey'),
                                  tween: Tween(begin: 0.94, end: 1.0),
                                  duration: const Duration(milliseconds: 240),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, scale, child) =>
                                      Transform.scale(
                                    scale: scale,
                                    alignment: Alignment.center,
                                    child: child,
                                  ),
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: cs.primary,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2.2,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: cs.primary.withValues(
                                            alpha: 0.45,
                                          ),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${day.day}',
                                      style: TextStyle(
                                        color: cs.onPrimary,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                );
                              },
                              todayBuilder: (context, day, focused) {
                                if (_isDayUnavailable(day)) return null;
                                final inRange =
                                    _rangeStart != null &&
                                    _rangeEnd != null &&
                                    !day.isBefore(_dateOnly(_rangeStart!)) &&
                                    !day.isAfter(_dateOnly(_rangeEnd!));
                                if (inRange) return null;
                                return Container(
                                  margin: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: cs.primary.withValues(alpha: 0.5),
                                      width: 2,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '${day.day}',
                                    style: TextStyle(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                );
                              },
                            ),
                            selectedDayPredicate: (_) => false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _BookingCalendarLegend(
                  isAr: _isAr,
                  colorScheme: cs,
                  theme: theme,
                ),
                if (_liveNights > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    _isAr
                        ? '$_liveNights ليالي — الإجمالي من الخادم بعد الضغط على احجز'
                        : '$_liveNights nights — total from server after you tap Book',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: _selectionHint == null
                      ? const SizedBox(height: 12)
                      : Padding(
                          key: ValueKey(_selectionHint),
                          padding: const EdgeInsets.only(top: 14),
                          child: Material(
                            color: _selectionHintIsUnavailableDateTap
                                ? cs.surfaceContainerHighest.withValues(
                                    alpha: 0.75,
                                  )
                                : _selectionHintIsMinStay
                                    ? cs.primary.withValues(alpha: 0.1)
                                : (_selectionHintIsBookedConflict
                                        ? Colors.red
                                        : cs.error)
                                    .withValues(alpha: 0.09),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    _selectionHintIsUnavailableDateTap
                                        ? Icons.not_interested_outlined
                                        : _selectionHintIsMinStay
                                        ? Icons.schedule_rounded
                                        : _selectionHintIsBookedConflict
                                        ? Icons.event_busy_rounded
                                        : Icons.info_outline_rounded,
                                    size: 22,
                                    color: _selectionHintIsUnavailableDateTap
                                        ? cs.onSurface.withValues(alpha: 0.55)
                                        : _selectionHintIsMinStay
                                        ? cs.primary.withValues(alpha: 0.9)
                                        : (_selectionHintIsBookedConflict
                                                ? Colors.red
                                                : cs.error)
                                            .withValues(alpha: 0.9),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _selectionHint!,
                                      style: TextStyle(
                                        color: _selectionHintIsUnavailableDateTap
                                            ? cs.onSurface.withValues(
                                                alpha: 0.82,
                                              )
                                            : _selectionHintIsMinStay
                                            ? cs.primary.withValues(alpha: 0.95)
                                            : (_selectionHintIsBookedConflict
                                                    ? Colors.red.shade900
                                                    : cs.error)
                                                .withValues(alpha: 0.95),
                                        fontWeight: FontWeight.w600,
                                        height: 1.35,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
                if (datesChipLabel != null) ...[
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: Material(
                      key: ValueKey<String>(datesChipLabel),
                      color: cs.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.date_range_rounded,
                              size: 22,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                datesChipLabel,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (widget.showInternalBar)
          _StickyBookingBar(
            isAr: _isAr,
            nights: _liveNights,
            totalLabel: totalLabel,
            breakdownLabel: breakdownLabel,
            omitBookButtonTotal: _liveNights > 0 && barTotal <= 0,
            isProvisional: _isProvisionalPricing,
            canBook: canBook,
            submitting: _submitting,
            bookButtonPressed: _bookButtonPressed,
            onPointerDown: canBook
                ? (_) => setState(() => _bookButtonPressed = true)
                : null,
            onPointerUp: (_) => setState(() => _bookButtonPressed = false),
            onPointerCancel: (_) => setState(() => _bookButtonPressed = false),
            onBook: _submit,
          ),
      ],
    );
  }
}

/// Listing owner: create/delete `blocked_dates` rows (`source: owner`) for this property.
class ChaletOwnerAvailabilityTools extends StatelessWidget {
  const ChaletOwnerAvailabilityTools({super.key, required this.propertyId});

  final String propertyId;

  static Future<void> _addBlock(BuildContext context, String propertyId) async {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day);
    final range = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: first.add(const Duration(days: 730)),
      helpText: isAr ? 'اختر فترة الحجب' : 'Select dates to block',
    );
    if (range == null || !context.mounted) return;

    final start = DateTime(range.start.year, range.start.month, range.start.day);
    final endInclusive =
        DateTime(range.end.year, range.end.month, range.end.day);
    if (endInclusive.isBefore(start)) return;

    final endExclusive = endInclusive.add(const Duration(days: 1));
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await FirebaseFirestore.instance.collection('blocked_dates').add({
        'propertyId': propertyId,
        'startDate': Timestamp.fromDate(start),
        'endDate': Timestamp.fromDate(endExclusive),
        'source': 'owner',
        'ownerId': uid,
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isAr ? 'تم حجب التواريخ' : 'Dates blocked'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.1)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.calendar_month_outlined,
                    size: 22,
                    color: cs.primary.withValues(alpha: 0.88),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isAr ? 'إدارة المواعيد المتاحة' : 'Manage available dates',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.28,
                      letterSpacing: isAr ? 0 : -0.25,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              isAr
                  ? 'يُرجى تحديد التواريخ للحجز'
                  : 'Please select the dates for booking.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.68),
                height: 1.45,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: uid == null
                  ? null
                  : () => _addBlock(context, propertyId),
              icon: const Icon(Icons.date_range_rounded),
              label: Text(isAr ? 'حدد التواريخ' : 'Select dates'),
            ),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('blocked_dates')
                  .where('propertyId', isEqualTo: propertyId)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      ),
                    ),
                  );
                }
                if (snap.hasError) {
                  final raw = snap.error.toString();
                  final denied = raw.contains('permission-denied') ||
                      raw.contains('PERMISSION_DENIED');
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      denied
                          ? (isAr ? 'تعذر تحميل الحجب. إن لم تكن قد نشرت قواعد Firestore الأحدث، نفّذ: firebase deploy --only firestore:rules ثم أعد فتح الشاشة.'
                              : 'Could not load blocks. Deploy latest Firestore rules (e.g. firebase deploy --only firestore:rules), then reopen this screen.')
                          : raw,
                      style: TextStyle(
                        color: cs.error,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  );
                }
                final docs = snap.data?.docs ?? [];
                final mine = docs.where((d) {
                  final m = d.data();
                  return m['source']?.toString() == 'owner' &&
                      m['ownerId']?.toString() == uid;
                }).toList()
                  ..sort((a, b) {
                    final ta = a.data()['startDate'];
                    final tb = b.data()['startDate'];
                    if (ta is Timestamp && tb is Timestamp) {
                      return ta.compareTo(tb);
                    }
                    return 0;
                  });

                if (mine.isEmpty) {
                  return const SizedBox.shrink();
                }

                final locale = isAr ? 'ar' : 'en_US';
                return Column(
                  children: mine.map((doc) {
                    final m = doc.data();
                    final s = m['startDate'];
                    final e = m['endDate'];
                    var line = '';
                    if (s is Timestamp && e is Timestamp) {
                      final last =
                          e.toDate().subtract(const Duration(days: 1));
                      line =
                          '${DateFormat.yMMMd(locale).format(s.toDate())} — ${DateFormat.yMMMd(locale).format(last)}';
                    }
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        line,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline, color: cs.error),
                        onPressed: () async {
                          try {
                            await doc.reference.delete();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    isAr ? 'تم إلغاء الحجب' : 'Block removed',
                                  ),
                                ),
                              );
                            }
                          } catch (err) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('$err')),
                              );
                            }
                          }
                        },
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _BookingCalendarLegend extends StatelessWidget {
  const _BookingCalendarLegend({
    required this.isAr,
    required this.colorScheme,
    required this.theme,
  });

  final bool isAr;
  final ColorScheme colorScheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final labelStyle = theme.textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurface.withValues(alpha: 0.78),
    );
    final sampleText =
        Colors.grey.shade600.withValues(alpha: 0.4);

    Widget item({required Widget swatch, required String label}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          swatch,
          const SizedBox(width: 8),
          Text(label, style: labelStyle),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        spacing: 18,
        runSpacing: 10,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          item(
            swatch: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: colorScheme.onSurface.withValues(alpha: 0.35),
                  width: 1.8,
                ),
              ),
            ),
            label: isAr ? 'متاح' : 'Available',
          ),
          item(
            swatch: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.grey.shade300.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '8',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: sampleText,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: sampleText.withValues(alpha: 0.45),
                  height: 1,
                ),
              ),
            ),
            label: isAr ? 'غير متاح' : 'Unavailable',
          ),
          item(
            swatch: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            label: isAr ? 'التواريخ المختارة' : 'Selected dates',
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, this.textStyle});

  final int day;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return Center(child: Text('$day', style: textStyle));
  }
}

class _BookingChrome extends StatelessWidget {
  const _BookingChrome({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      elevation: 2,
      shadowColor: cs.shadow.withValues(alpha: 0.18),
      color: cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
        child: child,
      ),
    );
  }
}
