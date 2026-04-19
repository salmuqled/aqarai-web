import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/l10n/app_localizations.dart';

/// Daily rental browse: list data from [searchDailyProperties] (Cloud Function).
class DailyRentPage extends StatefulWidget {
  const DailyRentPage({super.key});

  @override
  State<DailyRentPage> createState() => _DailyRentPageState();
}

class _DailyRentPageState extends State<DailyRentPage> {
  Timer? _debounce;

  DateTime? startDate;
  DateTime? endDate;

  String selectedRentalType = 'daily';

  List<Map<String, dynamic>> _properties = [];
  String? _nextCursor;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  final ScrollController _scrollController = ScrollController();
  int _cfFetchToken = 0;
  bool _cfFetching = false;

  /// True while a Cloud Function search is in flight (mirrors [_cfFetching] for UX copy).
  bool isSearching = false;

  static const Duration _searchDebounce = Duration(milliseconds: 450);

  void _scheduleDebouncedCfReload() {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (!mounted) return;
      _loadCfPage(append: false);
    });
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onCfScrollNearEnd);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadCfPage(append: false);
      }
    });
  }

  void _onCfScrollNearEnd() {
    if (!_scrollController.hasClients) return;
    if (_cfFetching || _isLoadingMore || !_hasMore) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      _loadCfPage(append: true);
    }
  }

  Future<void> _loadCfPage({required bool append}) async {
    if (_cfFetching) return;
    if (append && (!_hasMore || _nextCursor == null)) return;

    final cursorToSend = append ? _nextCursor : null;
    final token = ++_cfFetchToken;

    setState(() {
      _cfFetching = true;
      isSearching = true;
      if (append) {
        _isLoadingMore = true;
      } else {
        _properties = [];
        _nextCursor = null;
        _hasMore = true;
      }
    });

    try {
      final callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('searchDailyProperties');

      // Calendar-day bounds in UTC (ISO-8601) for searchDailyProperties availability.
      final s = startDate;
      final e = endDate;
      final DateTime? startUtc = (s != null && e != null)
          ? DateTime.utc(s.year, s.month, s.day)
          : null;
      final DateTime? endUtc = (s != null && e != null)
          ? DateTime.utc(e.year, e.month, e.day, 23, 59, 59, 999)
          : null;

      final payload = <String, dynamic>{
        'rentalType': selectedRentalType,
        if (cursorToSend != null) 'cursor': cursorToSend,
        if (startUtc != null && endUtc != null) 'startDate': startUtc.toIso8601String(),
        if (startUtc != null && endUtc != null) 'endDate': endUtc.toIso8601String(),
      };

      final raw = await callable.call(payload);

      if (!mounted || token != _cfFetchToken) return;

      final data = raw.data;
      if (data is! Map) {
        throw Exception('Invalid searchDailyProperties response');
      }
      final m = Map<String, dynamic>.from(data);
      if (m['success'] != true) {
        throw Exception('searchDailyProperties was not successful');
      }

      final rawList = m['properties'];
      final batch = <Map<String, dynamic>>[];
      if (rawList is List) {
        for (final item in rawList) {
          if (item is Map) {
            batch.add(Map<String, dynamic>.from(item));
          }
        }
      }

      final next = m['nextCursor'];
      final more = m['hasMore'] == true;

      setState(() {
        if (append) {
          _properties.addAll(batch);
        } else {
          _properties = batch;
        }
        _nextCursor = next is String && next.isNotEmpty ? next : null;
        _hasMore = more;
        _cfFetching = false;
        isSearching = false;
        _isLoadingMore = false;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted || token != _cfFetchToken) return;
      setState(() {
        _cfFetching = false;
        isSearching = false;
        _isLoadingMore = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(e.message ?? e.code),
          ),
        );
      }
    } catch (_) {
      if (!mounted || token != _cfFetchToken) return;
      setState(() {
        _cfFetching = false;
        isSearching = false;
        _isLoadingMore = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Could not load listings.'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onCfScrollNearEnd);
    _scrollController.dispose();
    _debounce?.cancel();
    super.dispose();
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
      initialDateRange: (startDate != null && endDate != null)
          ? DateTimeRange(
              start: DateTime(startDate!.year, startDate!.month, startDate!.day),
              end: DateTime(endDate!.year, endDate!.month, endDate!.day),
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
      startDate = picked.start;
      endDate = picked.end;
    });
    _scheduleDebouncedCfReload();
  }

  int? _stayNightCount() {
    if (startDate == null || endDate == null) return null;
    final s = DateTime(startDate!.year, startDate!.month, startDate!.day);
    final e = DateTime(endDate!.year, endDate!.month, endDate!.day);
    final n = e.difference(s).inDays;
    return n > 0 ? n : null;
  }

  String _formatDate(DateTime? d, String locale) {
    if (d == null) {
      return locale == 'ar' ? 'اختر التاريخ' : 'Add date';
    }
    return DateFormat.MMMEd(locale == 'ar' ? 'ar' : 'en').format(d);
  }

  Widget _bookingDateColumn({
    required BuildContext context,
    required String label,
    required DateTime? date,
    required String locale,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          _formatDate(date, locale),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
        ),
      ],
    );
  }

  Widget _buildBookingStayDatesCard(BuildContext context, String locale, bool isAr) {
    final scheme = Theme.of(context).colorScheme;
    final nights = _stayNightCount();
    return Material(
      color: scheme.surface,
      elevation: 0,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: _pickDateRange,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.85)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.surfaceContainerHighest.withValues(alpha: 0.2),
                scheme.surface,
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.calendar_month_rounded,
                      color: scheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _bookingDateColumn(
                            context: context,
                            label: isAr ? 'الوصول' : 'Check-in',
                            date: startDate,
                            locale: locale,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 20),
                          child: Icon(
                            Directionality.of(context) == ui.TextDirection.rtl
                                ? Icons.arrow_back_rounded
                                : Icons.arrow_forward_rounded,
                            size: 18,
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                          ),
                        ),
                        Expanded(
                          child: _bookingDateColumn(
                            context: context,
                            label: isAr ? 'المغادرة' : 'Check-out',
                            date: endDate,
                            locale: locale,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.expand_more_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (nights != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      child: Text(
                        isAr
                            ? '$nights ${nights == 1 ? 'ليلة' : 'ليالٍ'}'
                            : '$nights night${nights == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: scheme.onSecondaryContainer,
                            ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _clearDatesAndFilters() {
    _debounce?.cancel();
    setState(() {
      startDate = null;
      endDate = null;
    });
    _loadCfPage(append: false);
  }

  Widget _buildCfPaginatedList(
    BuildContext context,
    AppLocalizations loc,
    String locale,
    bool isAr,
    String areaTitle,
  ) {
    if (_cfFetching && _properties.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (startDate != null && endDate != null) ...[
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  isAr
                      ? 'يتم التحقق من التوفر لهذه الفترة.'
                      : 'Checking availability for these dates.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (!_cfFetching && _properties.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.home_work_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(
                loc.searchResultsForArea(areaTitle),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 20),
              TextButton(
                onPressed: _clearDatesAndFilters,
                child: Text(
                  isAr ? 'مسح التواريخ' : 'Clear dates',
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _properties.length + ((_hasMore && _isLoadingMore) ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _properties.length) {
          final item = _properties[index];
          return ListTile(
            title: Text(item['title']?.toString() ?? ''),
            subtitle: Text(item['price']?.toString() ?? ''),
          );
        }
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;
    final isAr = locale == 'ar';
    final areaTitle = isAr ? 'إيجار يومي' : 'Daily rental';

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        title: Text(loc.propertiesInArea(areaTitle)),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Material(
                color: Colors.white,
                elevation: 1,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<String>(
                        segments: [
                          ButtonSegment<String>(
                            value: 'daily',
                            label: Text(isAr ? 'يومي' : 'Daily'),
                          ),
                          ButtonSegment<String>(
                            value: 'monthly',
                            label: Text(isAr ? 'شهري / سنوي' : 'Monthly / Yearly'),
                          ),
                        ],
                        selected: {selectedRentalType},
                        onSelectionChanged: (Set<String> next) {
                          if (next.isEmpty) return;
                          final v = next.first;
                          if (v == selectedRentalType) return;
                          _debounce?.cancel();
                          setState(() => selectedRentalType = v);
                          _loadCfPage(append: false);
                        },
                        multiSelectionEnabled: false,
                        emptySelectionAllowed: false,
                        showSelectedIcon: false,
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: _cfFetching
                            ? null
                            : () {
                                _debounce?.cancel();
                                _loadCfPage(append: false);
                              },
                        icon: _cfFetching
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.search_rounded, size: 22),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            isAr ? 'بحث' : 'Search',
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
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    isAr ? 'تواريخ الإقامة' : 'Stay dates',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: isAr ? 0 : -0.2,
                        ),
                  ),
                  const SizedBox(height: 8),
                  _buildBookingStayDatesCard(context, locale, isAr),
                ],
              ),
            ),
            if (isSearching && startDate != null && endDate != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: const LinearProgressIndicator(minHeight: 3),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isAr
                          ? 'جاري البحث مع تطبيق التواريخ والتوفر…'
                          : 'Searching with your dates and availability…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _buildCfPaginatedList(
                      context,
                      loc,
                      locale,
                      isAr,
                      areaTitle,
                    ),
                  ),
                  if (_cfFetching && _properties.isNotEmpty)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
