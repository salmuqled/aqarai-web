import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Pure-UI stay-dates picker (check-in / check-out selector).
///
/// Visuals ported 1:1 from the original implementation that lived inside
/// `DailyRentPage` — same horizontal strip, same day chip, same nights badge,
/// same calendar shortcut + clear button.
///
/// NO business logic lives here. The widget only emits two callbacks:
///
///   * [onSearch]  — user picked / confirmed a date range (auto on range
///                   completion, on calendar confirm, and on the explicit
///                   Search button if [showSearchButton] is true).
///   * [onClear]   — user tapped the Clear button.
///
/// Caller owns debouncing, networking, and filtering.
class StayDatesPicker extends StatefulWidget {
  /// Initial check-in. Picker resets internal state when this changes.
  final DateTime? initialStartDate;

  /// Initial check-out. Picker resets internal state when this changes.
  final DateTime? initialEndDate;

  /// Fired with a valid [start] < [end] range:
  ///   * on completing a range via day-chip taps,
  ///   * on confirming the full calendar dialog,
  ///   * on tapping the Search button (when [showSearchButton] is true).
  final void Function(DateTime start, DateTime end) onSearch;

  /// Fired when the user taps the inline Clear button.
  final VoidCallback onClear;

  /// Drives the Search button spinner; also dims day chips/Calendar while true.
  final bool isSearching;

  /// When false, the embedded FilledButton is hidden and the host page is
  /// expected to provide its own search trigger (e.g. `daily_rent_page.dart`
  /// keeps its own standalone search button to preserve the current layout).
  final bool showSearchButton;

  /// Number of days rendered in the horizontal strip; starts from today.
  final int stripDays;

  const StayDatesPicker({
    super.key,
    this.initialStartDate,
    this.initialEndDate,
    required this.onSearch,
    required this.onClear,
    this.isSearching = false,
    this.showSearchButton = true,
    this.stripDays = 90,
  });

  @override
  State<StayDatesPicker> createState() => _StayDatesPickerState();
}

class _StayDatesPickerState extends State<StayDatesPicker> {
  DateTime? _startDate;
  DateTime? _endDate;

  late final List<DateTime> _dateStrip = _buildDateStripDays(widget.stripDays);
  final ScrollController _dateStripController = ScrollController();

  @override
  void initState() {
    super.initState();
    _startDate = widget.initialStartDate;
    _endDate = widget.initialEndDate;
  }

  @override
  void didUpdateWidget(covariant StayDatesPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Allow the host to externally reset / sync dates (e.g. after a clear on
    // another trigger). We compare whole-day values so a parent re-render that
    // passes the same day with a different time doesn't thrash selection.
    final changedStart = !_sameDay(widget.initialStartDate, oldWidget.initialStartDate);
    final changedEnd = !_sameDay(widget.initialEndDate, oldWidget.initialEndDate);
    if (changedStart || changedEnd) {
      setState(() {
        _startDate = widget.initialStartDate;
        _endDate = widget.initialEndDate;
      });
    }
  }

  @override
  void dispose() {
    _dateStripController.dispose();
    super.dispose();
  }

  static bool _sameDay(DateTime? a, DateTime? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  static List<DateTime> _buildDateStripDays(int count) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return List<DateTime>.generate(
      count,
      (i) => today.add(Duration(days: i)),
    );
  }

  int? _stayNightCount() {
    if (_startDate == null || _endDate == null) return null;
    final s = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
    final e = DateTime(_endDate!.year, _endDate!.month, _endDate!.day);
    final n = e.difference(s).inDays;
    return n > 0 ? n : null;
  }

  /// Header label — tracks the user's check-in month, else current month.
  String _stripMonthLabel(String locale) {
    final anchor = _startDate ?? DateTime.now();
    try {
      return DateFormat.yMMMM(locale == 'ar' ? 'ar' : 'en').format(anchor);
    } catch (_) {
      return DateFormat.yMMMM('en').format(anchor);
    }
  }

  /// Selection rules (check-in / check-out):
  ///   * No selection yet     → [_startDate] = [day], wait for check-out tap.
  ///   * Start set, end null, tap > start → set [_endDate] + fire [onSearch].
  ///   * Tap same day as start → clear selection.
  ///   * Tap before start      → treat tap as new check-in, clear end.
  ///   * Both already set      → start a fresh range from the tapped day.
  void _onDayTap(DateTime day) {
    final tapped = DateTime(day.year, day.month, day.day);
    setState(() {
      if (_startDate == null) {
        _startDate = tapped;
        _endDate = null;
      } else if (_endDate != null) {
        _startDate = tapped;
        _endDate = null;
      } else {
        final s = DateTime(_startDate!.year, _startDate!.month, _startDate!.day);
        if (tapped == s) {
          _startDate = null;
          _endDate = null;
        } else if (tapped.isBefore(s)) {
          _startDate = tapped;
          _endDate = null;
        } else {
          _endDate = tapped;
        }
      }
    });

    final s = _startDate;
    final e = _endDate;
    if (s != null && e != null) {
      widget.onSearch(s, e);
    }
  }

  Future<void> _pickDateRange() async {
    if (!mounted) return;
    final locale = Localizations.localeOf(context).languageCode;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      initialDateRange: (_startDate != null && _endDate != null)
          ? DateTimeRange(
              start: DateTime(_startDate!.year, _startDate!.month, _startDate!.day),
              end: DateTime(_endDate!.year, _endDate!.month, _endDate!.day),
            )
          : null,
      helpText: locale == 'ar' ? 'اختر فترة الإيجار' : 'Select rental period',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0EA5E9),
              brightness: Theme.of(context).brightness,
            ),
          ),
          child: child!,
        );
      },
    );
    if (!mounted || picked == null) return;
    setState(() {
      _startDate = picked.start;
      _endDate = picked.end;
    });
    widget.onSearch(picked.start, picked.end);
  }

  void _handleClear() {
    setState(() {
      _startDate = null;
      _endDate = null;
    });
    widget.onClear();
  }

  void _handleSearchButton() {
    final s = _startDate;
    final e = _endDate;
    if (s == null || e == null) return;
    widget.onSearch(s, e);
  }

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    final isAr = locale == 'ar';
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStayDatesCard(context, locale, isAr, scheme),
        if (widget.showSearchButton) ...[
          const SizedBox(height: 12),
          _buildSearchButton(context, isAr),
        ],
      ],
    );
  }

  Widget _buildSearchButton(BuildContext context, bool isAr) {
    final hasRange = _startDate != null && _endDate != null;
    return FilledButton.icon(
      onPressed: (widget.isSearching || !hasRange) ? null : _handleSearchButton,
      icon: widget.isSearching
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.search_rounded, size: 22),
      label: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          hasRange
              ? (isAr ? 'بحث عن الشاليهات المتاحة' : 'Find available chalets')
              : (isAr ? 'بحث' : 'Search'),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Widget _buildStayDatesCard(
    BuildContext context,
    String locale,
    bool isAr,
    ColorScheme scheme,
  ) {
    final nights = _stayNightCount();
    final hasAnySelection = _startDate != null || _endDate != null;

    return Material(
      color: scheme.surface,
      elevation: 0,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.85),
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surfaceContainerHighest.withValues(alpha: 0.18),
              scheme.surface,
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: icon + title + month label + calendar shortcut.
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 8, 8),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      Icons.calendar_month_rounded,
                      color: scheme.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isAr ? 'اختر تواريخ الإقامة' : 'Select stay dates',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                              ),
                        ),
                        Text(
                          _stripMonthLabel(locale),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                              ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: widget.isSearching ? null : _pickDateRange,
                    icon: Icon(
                      Icons.event_rounded,
                      size: 16,
                      color: scheme.primary,
                    ),
                    label: Text(
                      isAr ? 'التقويم' : 'Calendar',
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      backgroundColor:
                          scheme.primaryContainer.withValues(alpha: 0.35),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Horizontal scrollable days strip.
            SizedBox(
              height: 86,
              child: ListView.separated(
                controller: _dateStripController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                physics: const BouncingScrollPhysics(),
                itemCount: _dateStrip.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  return _buildDayChip(context, _dateStrip[i], locale, isAr);
                },
              ),
            ),
            const SizedBox(height: 6),
            // Footer: nights badge / helper copy + clear shortcut.
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 10, 12),
              child: Row(
                children: [
                  if (nights != null)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.nightlight_round,
                              size: 14,
                              color: scheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isAr
                                  ? '$nights ${nights == 1 ? 'ليلة' : 'ليالٍ'}'
                                  : '$nights night${nights == 1 ? '' : 's'}',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSecondaryContainer,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: Text(
                        _startDate == null
                            ? (isAr
                                ? 'اضغط يوم الوصول ثم يوم المغادرة'
                                : 'Tap check-in, then check-out')
                            : (isAr
                                ? 'اختر يوم المغادرة'
                                : 'Pick a check-out day'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  const Spacer(),
                  if (hasAnySelection)
                    TextButton.icon(
                      // Kept enabled during in-flight search so the user can
                      // always cancel; parent invalidates the request via its
                      // availability-search token in `onClear`.
                      onPressed: _handleClear,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: scheme.error,
                      ),
                      label: Text(
                        isAr ? 'مسح' : 'Clear',
                        style: TextStyle(
                          color: scheme.error,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDayChip(
    BuildContext context,
    DateTime date,
    String locale,
    bool isAr,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);

    final sDate = _startDate;
    final eDate = _endDate;
    final s = sDate != null ? DateTime(sDate.year, sDate.month, sDate.day) : null;
    final e = eDate != null ? DateTime(eDate.year, eDate.month, eDate.day) : null;

    final isStart = s != null && d == s;
    final isEnd = e != null && d == e;
    final isEdge = isStart || isEnd;
    final inRange = s != null && e != null && d.isAfter(s) && d.isBefore(e);
    final isToday = d == today;
    final isFirstOfMonth = d.day == 1;

    String dayName;
    try {
      dayName = DateFormat.E(locale == 'ar' ? 'ar' : 'en').format(d);
    } catch (_) {
      dayName = DateFormat.E('en').format(d);
    }

    Color bg;
    Color fg;
    BoxBorder? border;
    List<BoxShadow>? shadow;
    if (isEdge) {
      bg = scheme.primary;
      fg = scheme.onPrimary;
      shadow = [
        BoxShadow(
          color: scheme.primary.withValues(alpha: 0.28),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ];
    } else if (inRange) {
      bg = scheme.primaryContainer.withValues(alpha: 0.55);
      fg = scheme.onPrimaryContainer;
    } else {
      bg = scheme.surface;
      fg = scheme.onSurface;
      border = Border.all(
        color: isToday
            ? scheme.primary.withValues(alpha: 0.75)
            : scheme.outlineVariant.withValues(alpha: 0.85),
        width: isToday ? 1.5 : 1,
      );
    }

    String? edgeBadge;
    if (isStart && isEnd) {
      edgeBadge = isAr ? 'ليلة' : '1 night';
    } else if (isStart) {
      edgeBadge = isAr ? 'وصول' : 'Check-in';
    } else if (isEnd) {
      edgeBadge = isAr ? 'مغادرة' : 'Check-out';
    }

    String? footerLine;
    Widget? footerDot;
    if (isFirstOfMonth) {
      try {
        footerLine = DateFormat.MMM(locale == 'ar' ? 'ar' : 'en').format(d);
      } catch (_) {
        footerLine = DateFormat.MMM('en').format(d);
      }
    } else if (isToday) {
      footerDot = Container(
        width: 4,
        height: 4,
        decoration: BoxDecoration(
          color: isEdge ? fg : scheme.primary,
          shape: BoxShape.circle,
        ),
      );
    }

    return InkWell(
      onTap: widget.isSearching ? null : () => _onDayTap(d),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 58,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: border,
          boxShadow: shadow,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              dayName,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isEdge
                    ? fg.withValues(alpha: 0.9)
                    : scheme.onSurfaceVariant,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${d.day}',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: fg,
                height: 1.05,
              ),
            ),
            const SizedBox(height: 4),
            if (edgeBadge != null)
              Text(
                edgeBadge,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: fg.withValues(alpha: 0.9),
                  height: 1.1,
                ),
              )
            else if (footerLine != null)
              Text(
                footerLine,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: isEdge
                      ? fg.withValues(alpha: 0.85)
                      : scheme.primary,
                  height: 1.1,
                ),
              )
            else if (footerDot != null)
              footerDot
            else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
