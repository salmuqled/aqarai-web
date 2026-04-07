// lib/widgets/chalet_booking_widget.dart
//
// Airbnb-style chalet booking UI: range calendar, confirmed blocks, price summary, [ChaletBookingService].

import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import 'package:aqarai_app/services/chalet_booking_service.dart';

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
  }) {
    if (_sameDay(_startDate, startDate) &&
        _sameDay(_endDate, endDate) &&
        nightsVN.value == nights &&
        totalPriceVN.value == totalPrice &&
        canBookVN.value == canBook &&
        isProvisionalVN.value == isProvisional &&
        submittingVN.value == submitting &&
        identical(_submit, submit)) {
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
  }

  static bool _sameDay(DateTime? a, DateTime? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  void submit() => _submit?.call();

  void dispose() {
    nightsVN.dispose();
    totalPriceVN.dispose();
    canBookVN.dispose();
    isProvisionalVN.dispose();
    submittingVN.dispose();
  }
}

/// One confirmed reservation interval (`startDate` / `endDate` from Firestore, as stored).
class ChaletBookedRange {
  const ChaletBookedRange({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
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

/// Premium booking card for chalet listings. Does not change backend behavior.
class ChaletBookingWidget extends StatelessWidget {
  const ChaletBookingWidget({
    super.key,
    required this.propertyId,
    required this.pricePerNight,
    this.currencyCode = 'KWD',
    this.controller,
    this.useExternalBookingBar = false,
  });

  final String propertyId;
  final double pricePerNight;
  final String currencyCode;
  final ChaletBookingController? controller;

  /// When true, the booking bar is expected to be rendered by a parent `Scaffold`
  /// (e.g. `bottomNavigationBar`), and the widget will not render its internal bar.
  final bool useExternalBookingBar;

  static List<ChaletBookedRange> _rangesFromSnapshot(
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

    final bookedFill = Colors.red.withValues(alpha: 0.13);
    final bookedBorder = Colors.red.withValues(alpha: 0.28);

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
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _LegendDot(
                        color: cs.primary,
                        label: isAr ? 'مختارة' : 'Selected',
                      ),
                      const SizedBox(width: 16),
                      _LegendDot(
                        color: bookedFill,
                        border: bookedBorder,
                        label: isAr ? 'محجوزة' : 'Booked',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: math.min(
                      MediaQuery.sizeOf(context).height * 0.62,
                      580,
                    ),
                    child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('bookings')
                          .where('propertyId', isEqualTo: propertyId)
                          .where('status', isEqualTo: 'confirmed')
                          .snapshots(),
                      builder: (context, snap) {
                        final waitingFirstLoad =
                            snap.connectionState == ConnectionState.waiting &&
                            !snap.hasData;
                        if (waitingFirstLoad) {
                          return const _CalendarSkeleton();
                        }
                        if (snap.hasError) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              snap.error.toString(),
                              style: TextStyle(color: cs.error),
                            ),
                          );
                        }
                        final ranges = _rangesFromSnapshot(
                          snap.data?.docs ?? [],
                        );
                        final today = DateTime(
                          DateTime.now().year,
                          DateTime.now().month,
                          DateTime.now().day,
                        );
                        if (!chaletHorizonHasAvailableDay(ranges, today)) {
                          return _NoAvailabilityBody(
                            isAr: isAr,
                            pricePerNight: pricePerNight,
                            currencyCode: currencyCode,
                            showInternalBar: !useExternalBookingBar,
                          );
                        }
                        return _ChaletBookingBody(
                          propertyId: propertyId,
                          pricePerNight: pricePerNight,
                          currencyCode: currencyCode,
                          bookedRanges: ranges,
                          controller: controller,
                          showInternalBar: !useExternalBookingBar,
                        );
                      },
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

/// Always visible: "25 KWD / night" (localized).
class _PriceNightHeader extends StatelessWidget {
  const _PriceNightHeader({
    required this.formattedPrice,
    required this.currency,
    required this.isAr,
  });

  final String formattedPrice;
  final String currency;
  final bool isAr;

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
        children: [
          Icon(Icons.sell_outlined, size: 22, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$formattedPrice $currency / $nightLabel',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onPrimaryContainer,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shimmer-like placeholder until first Firestore snapshot arrives.
class _CalendarSkeleton extends StatefulWidget {
  const _CalendarSkeleton();

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
    required this.pricePerNightLabel,
    required this.nights,
    required this.totalLabel,
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
  final String pricePerNightLabel;
  final int nights;
  final String totalLabel;
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
                        Text(isAr ? 'لليلة' : 'Per night', style: labelStyle),
                        const SizedBox(height: 2),
                        Text(pricePerNightLabel, style: valueStyle),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          isAr ? 'ليالي' : 'Nights',
                          style: labelStyle,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 2),
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
                            textAlign: TextAlign.center,
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
                          isAr ? 'الإجمالي' : 'Total',
                          style: labelStyle,
                          textAlign: TextAlign.end,
                        ),
                        const SizedBox(height: 2),
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
                            isAr ? 'احجز الآن' : 'Book now',
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
    final perNight = '${fmt.format(pricePerNight)} $currencyCode';

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
            pricePerNightLabel: perNight,
            nights: 0,
            totalLabel: '${fmt.format(0)} $currencyCode',
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
    required this.pricePerNight,
    required this.currencyCode,
    required this.bookedRanges,
    required this.showInternalBar,
    this.controller,
  });

  final String propertyId;
  final double pricePerNight;
  final String currencyCode;
  final List<ChaletBookedRange> bookedRanges;
  final bool showInternalBar;
  final ChaletBookingController? controller;

  @override
  State<_ChaletBookingBody> createState() => _ChaletBookingBodyState();
}

class _ChaletBookingBodyState extends State<_ChaletBookingBody> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _rangeStart;
  DateTime? _rangeEnd;
  bool _submitting = false;
  bool _bookButtonPressed = false;
  String? _selectionHint;
  bool _selectionHintIsBookedConflict = false;

  bool get _isAr => Localizations.localeOf(context).languageCode == 'ar';

  String get _msgBookedOrPartialAvailability => _isAr
      ? 'بعض الأيام المختارة محجوزة'
      : 'Selected dates are not fully available';

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
    if (_rangeConflicts(checkIn, checkOutExclusive)) return null;
    if (_stayHasBlockedNight(checkIn, checkOutExclusive)) return null;
    return (checkIn, checkOutExclusive);
  }

  (DateTime checkIn, DateTime checkOutExclusive)? get _liveStayBounds =>
      _computeStayBounds() ?? _provisionalBounds;

  int get _liveNights {
    final b = _liveStayBounds;
    if (b == null) return 0;
    return math.max(0, b.$2.difference(b.$1).inDays);
  }

  double get _liveTotal =>
      (widget.pricePerNight * _liveNights * 1000).round() / 1000;

  bool get _isProvisionalPricing =>
      _computeStayBounds() == null && _provisionalBounds != null;

  /// Book button enabled only with full range and no conflict (matches UX spec).
  bool get _isValidSelection {
    if (_rangeStart == null || _rangeEnd == null) return false;
    final bounds = _computeStayBounds();
    if (bounds == null || _nights < 1) return false;
    if (_rangeConflicts(bounds.$1, bounds.$2)) return false;
    if (_stayHasBlockedNight(bounds.$1, bounds.$2)) return false;
    return true;
  }

  void _showRangeBlockedFeedback() {
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
            Expanded(child: Text(_msgBookedOrPartialAvailability)),
          ],
        ),
        backgroundColor: Colors.red.shade900.withValues(alpha: 0.92),
      ),
    );
  }

  void _onRangeSelected(DateTime? start, DateTime? end, DateTime focusedDay) {
    setState(() {
      _focusedDay = focusedDay;
      _selectionHint = null;
      _selectionHintIsBookedConflict = false;
      if (start != null && end == null) {
        if (_isDayUnavailable(start)) {
          _rangeStart = null;
          _rangeEnd = null;
          if (_isBookedNight(_dateOnly(start))) {
            _selectionHint = _msgBookedOrPartialAvailability;
            _selectionHintIsBookedConflict = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showRangeBlockedFeedback();
            });
          } else {
            _selectionHint = _isAr
                ? 'لا يمكن اختيار تاريخ سابق'
                : 'Past dates can’t be selected';
          }
        } else {
          _rangeStart = start;
          _rangeEnd = null;
        }
      } else if (start != null && end != null) {
        var a = _dateOnly(start.isBefore(end) ? start : end);
        var b = _dateOnly(start.isBefore(end) ? end : start);
        if (a.isAfter(b)) {
          final t = a;
          a = b;
          b = t;
        }
        if (a == b) {
          _rangeStart = null;
          _rangeEnd = null;
          _selectionHint = _isAr
              ? 'مدة الإقامة غير صالحة'
              : 'Invalid stay length';
          return;
        }
        final checkIn = a;
        final checkOutExclusive = b.add(const Duration(days: 1));
        if (_rangeConflicts(checkIn, checkOutExclusive) ||
            _stayHasBlockedNight(checkIn, checkOutExclusive)) {
          _rangeStart = null;
          _rangeEnd = null;
          _selectionHint = _msgBookedOrPartialAvailability;
          _selectionHintIsBookedConflict = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showRangeBlockedFeedback();
          });
        } else {
          _rangeStart = a;
          _rangeEnd = b;
        }
      } else {
        _rangeStart = null;
        _rangeEnd = null;
      }
    });
  }

  Future<void> _submit() async {
    if (!_isValidSelection) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isAr ? 'سجّل الدخول لإكمال الحجز' : 'Sign in to complete booking',
          ),
        ),
      );
      return;
    }

    final bounds = _computeStayBounds();
    if (bounds == null || _nights < 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isAr
                ? 'اختر تواريخ الوصول والمغادرة'
                : 'Select check-in and check-out',
          ),
        ),
      );
      return;
    }

    setState(() => _submitting = true);
    final result = await ChaletBookingService.createBooking(
      propertyId: widget.propertyId,
      startDate: bounds.$1,
      endDate: bounds.$2,
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (result.ok) {
      setState(() {
        _rangeStart = null;
        _rangeEnd = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            _isAr ? 'تم إرسال طلب الحجز بنجاح' : 'Booking request submitted',
          ),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } else {
      final msg = result.errorMessage ?? '';
      final taken =
          msg.toLowerCase().contains('overlap') ||
          msg.toLowerCase().contains('already') ||
          msg.contains('booked') ||
          msg.contains('تعارض');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(taken ? _msgBookedOrPartialAvailability : msg),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final locale = _isAr ? 'ar' : 'en_US';
    final fmt = NumberFormat.decimalPattern(_isAr ? 'ar' : 'en');

    final bookedFill = Colors.red.withValues(alpha: 0.13);
    final bookedBorder = Colors.red.withValues(alpha: 0.28);
    final bookedText = Colors.red.shade900.withValues(alpha: 0.78);

    final rangeKey =
        '${_rangeStart?.toIso8601String()}_${_rangeEnd?.toIso8601String()}';

    final canBook = _isValidSelection && !_submitting;
    final perNightLabel =
        '${fmt.format(widget.pricePerNight)} ${widget.currencyCode}';
    final totalLabel = '${fmt.format(_liveTotal)} ${widget.currencyCode}';
    final boundsLive = _liveStayBounds;
    String? datesChipLabel;
    if (boundsLive != null) {
      final lastNight = boundsLive.$2.subtract(const Duration(days: 1));
      datesChipLabel =
          '${DateFormat.yMMMd(locale).format(boundsLive.$1)} → ${DateFormat.yMMMd(locale).format(lastNight)}';
    }

    widget.controller?._update(
      startDate: boundsLive?.$1,
      endDate: boundsLive?.$2.subtract(const Duration(days: 1)),
      nights: _liveNights,
      totalPrice: _liveTotal,
      canBook: canBook,
      isProvisional: _isProvisionalPricing,
      submitting: _submitting,
      submit: canBook ? _submit : null,
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
                            firstDay: _today.subtract(const Duration(days: 1)),
                            lastDay: _today.add(const Duration(days: 500)),
                            focusedDay: _focusedDay,
                            rangeStartDay: _rangeStart,
                            rangeEndDay: _rangeEnd,
                            rangeSelectionMode: RangeSelectionMode.toggledOn,
                            enabledDayPredicate: (day) =>
                                !_isDayUnavailable(day),
                            onRangeSelected: _onRangeSelected,
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
                                color: cs.onSurface.withValues(alpha: 0.3),
                              ),
                              outsideDaysVisible: false,
                              rangeHighlightColor: cs.primary.withValues(
                                alpha: 0.2,
                              ),
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
                              defaultBuilder: (context, day, focused) {
                                return _DayCell(
                                  day: day.day,
                                  textStyle: theme.textTheme.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                );
                              },
                              disabledBuilder: (context, day, focused) {
                                final booked = _isBookedNight(_dateOnly(day));
                                if (booked) {
                                  return Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: bookedFill,
                                      borderRadius: BorderRadius.circular(11),
                                      border: Border.all(
                                        color: bookedBorder,
                                        width: 1,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${day.day}',
                                      style: TextStyle(
                                        color: bookedText,
                                        fontWeight: FontWeight.w700,
                                        decoration: TextDecoration.lineThrough,
                                        decorationColor: bookedText.withValues(
                                          alpha: 0.7,
                                        ),
                                      ),
                                    ),
                                  );
                                }
                                return Container(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 2,
                                    vertical: 3,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '${day.day}',
                                    style: TextStyle(
                                      color: cs.onSurface.withValues(
                                        alpha: 0.32,
                                      ),
                                      decoration: TextDecoration.lineThrough,
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
                            color:
                                (_selectionHintIsBookedConflict
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
                                    _selectionHintIsBookedConflict
                                        ? Icons.event_busy_rounded
                                        : Icons.info_outline_rounded,
                                    size: 22,
                                    color:
                                        (_selectionHintIsBookedConflict
                                                ? Colors.red
                                                : cs.error)
                                            .withValues(alpha: 0.9),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _selectionHint!,
                                      style: TextStyle(
                                        color:
                                            (_selectionHintIsBookedConflict
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
            pricePerNightLabel: perNightLabel,
            nights: _liveNights,
            totalLabel: totalLabel,
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

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label, this.border});

  final Color color;
  final String label;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: border != null
                ? Border.all(color: border!, width: 1)
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.75),
          ),
        ),
      ],
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
