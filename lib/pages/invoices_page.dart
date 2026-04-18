import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/pages/invoice_viewer_page.dart';

class InvoicesPage extends StatefulWidget {
  const InvoicesPage({super.key});

  @override
  State<InvoicesPage> createState() => _InvoicesPageState();
}

enum _DateFilter { today, last7, last30, all, specificMonth }

enum _SortOption { newest, highestAmount, lowestAmount }

class _InvoicesPageState extends State<InvoicesPage> {
  static const int _pageSize = 20;

  bool _isAdmin = false;
  bool _loadingRole = true;

  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();

  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  Object? _loadError;

  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];

  final Map<String, String> _propertyTitleCache = <String, String>{};
  final Set<String> _propertyFetchInFlight = <String>{};

  _DateFilter _dateFilter = _DateFilter.last30;
  _SortOption _sort = _SortOption.newest;
  String _propertyFilterId = '';
  DateTime? _selectedMonth;

  bool get _isAr => Localizations.localeOf(context).languageCode == 'ar';
  String get _currency => _isAr ? 'د.ك' : 'KWD';

  String get _searchText => _searchCtrl.text.trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    _loadRole();
    _scroll.addListener(_onScroll);
    _searchCtrl.addListener(() {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRole() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _isAdmin = false;
        _loadingRole = false;
      });
      return;
    }
    try {
      final token = await user.getIdTokenResult(true);
      final adminClaim = token.claims?['admin'];
      final isAdmin = adminClaim == true || adminClaim?.toString() == 'true';
      if (!mounted) return;
      setState(() {
        _isAdmin = isAdmin;
        _loadingRole = false;
      });
      await _reload();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isAdmin = false;
        _loadingRole = false;
      });
      await _reload();
    }
  }

  Query<Map<String, dynamic>> _queryInvoices(String uid) {
    final col = FirebaseFirestore.instance.collection('invoices');
    Query<Map<String, dynamic>> q = col;
    if (!_isAdmin) {
      q = q.where('clientId', isEqualTo: uid);
    }
    if (_dateFilter == _DateFilter.specificMonth && _selectedMonth != null) {
      final start = DateTime(_selectedMonth!.year, _selectedMonth!.month, 1);
      final end = DateTime(start.year, start.month + 1, 1);
      q = q
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where('createdAt', isLessThan: Timestamp.fromDate(end));
    } else {
      final since = _sinceForFilter(_dateFilter);
      if (since != null) {
        q = q.where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since));
      }
    }
    return q.orderBy('createdAt', descending: true).limit(_pageSize);
  }

  DateTime? _sinceForFilter(_DateFilter f) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (f) {
      case _DateFilter.today:
        return today;
      case _DateFilter.last7:
        return today.subtract(const Duration(days: 7));
      case _DateFilter.last30:
        return today.subtract(const Duration(days: 30));
      case _DateFilter.all:
        return null;
      case _DateFilter.specificMonth:
        return null;
    }
  }

  String _monthFilterLabel() {
    final m = _selectedMonth;
    if (m == null) return '';
    return DateFormat.yMMMM(_isAr ? 'ar' : 'en_US').format(m);
  }

  Future<void> _pickMonth() async {
    final now = DateTime.now();
    final initial =
        _selectedMonth ?? DateTime(now.year, now.month, 1);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(now.year + 2, 12, 31),
      helpText: _isAr ? 'اختر الشهر' : 'Select month',
      cancelText: _isAr ? 'إلغاء' : 'Cancel',
      confirmText: _isAr ? 'موافق' : 'OK',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedMonth = DateTime(picked.year, picked.month, 1);
      _dateFilter = _DateFilter.specificMonth;
    });
    await _reload();
  }

  void _clearMonthFilter() {
    setState(() {
      _selectedMonth = null;
      _dateFilter = _DateFilter.last30;
    });
    void _ = _reload();
  }

  void _onDateFilterChanged(_DateFilter v) {
    setState(() {
      _dateFilter = v;
      if (v != _DateFilter.specificMonth) {
        _selectedMonth = null;
      } else if (_selectedMonth == null) {
        final n = DateTime.now();
        _selectedMonth = DateTime(n.year, n.month, 1);
      }
    });
    void _ = _reload();
  }

  Future<void> _reload() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() {
      _initialLoading = true;
      _loadingMore = false;
      _hasMore = true;
      _loadError = null;
      _lastDoc = null;
      _docs.clear();
      _propertyFilterId = '';
    });
    await _fetchNextPage();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore || _loadError != null) return;
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels >= (p.maxScrollExtent - 480)) {
      void _ = _fetchNextPage();
    }
  }

  Future<void> _fetchNextPage() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (_loadingMore || !_hasMore) return;

    setState(() {
      _loadingMore = true;
      _loadError = null;
    });

    try {
      var q = _queryInvoices(user.uid);
      if (_lastDoc != null) {
        q = q.startAfterDocument(_lastDoc!);
      }
      final snap = await q.get();
      final newDocs = snap.docs;
      if (!mounted) return;

      if (newDocs.isNotEmpty) {
        _lastDoc = newDocs.last;
      }

      _docs.addAll(newDocs);
      _hasMore = newDocs.length >= _pageSize;

      await _preloadPropertyTitlesForDocs(newDocs);

      setState(() {
        _loadingMore = false;
        _initialLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loadingMore = false;
        _initialLoading = false;
      });
    }
  }

  Future<void> _preloadPropertyTitlesForDocs(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) async {
    final ids = <String>{};
    for (final d in docs) {
      final pid = (d.data()['propertyId'] ?? '').toString().trim();
      if (pid.isEmpty) continue;
      if (_propertyTitleCache.containsKey(pid)) continue;
      if (_propertyFetchInFlight.contains(pid)) continue;
      ids.add(pid);
    }
    if (ids.isEmpty) return;

    // Fetch in chunks of 10 (Firestore whereIn limit).
    final list = ids.toList(growable: false);
    for (var i = 0; i < list.length; i += 10) {
      final chunk = list.sublist(i, (i + 10) > list.length ? list.length : (i + 10));
      _propertyFetchInFlight.addAll(chunk);
      try {
        final snap = await FirebaseFirestore.instance
            .collection('properties')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final doc in snap.docs) {
          final m = doc.data();
          final area =
              (m[_isAr ? 'areaAr' : 'areaEn'] ?? m['area'] ?? '').toString().trim();
          final type = (m['type'] ?? '').toString().trim();
          final title = '${area}${type.isNotEmpty ? ' • $type' : ''}'.trim();
          _propertyTitleCache[doc.id] = title.isNotEmpty ? title : doc.id;
        }
        for (final pid in chunk) {
          _propertyTitleCache.putIfAbsent(pid, () => pid);
        }
      } catch (_) {
        for (final pid in chunk) {
          _propertyTitleCache.putIfAbsent(pid, () => pid);
        }
      } finally {
        _propertyFetchInFlight.removeAll(chunk);
      }
      if (mounted) setState(() {});
    }
  }

  double _dnum(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse((v ?? '0').toString()) ?? 0;
  }

  DateTime? _asDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    return null;
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _visibleDocs() {
    final q = _searchText;
    final out = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    for (final d in _docs) {
      final m = d.data();
      final pid = (m['propertyId'] ?? '').toString().trim();
      if (_propertyFilterId.isNotEmpty && pid != _propertyFilterId) {
        continue;
      }

      if (q.isNotEmpty) {
        final bookingId = (m['bookingId'] ?? '').toString().trim().toLowerCase();
        final title = (_propertyTitleCache[pid] ?? pid).toLowerCase();
        if (!bookingId.contains(q) && !title.contains(q)) continue;
      }

      out.add(d);
    }

    // Client-side sort (keeps pagination stable by createdAt).
    switch (_sort) {
      case _SortOption.newest:
        // already by createdAt desc from query; keep stable.
        break;
      case _SortOption.highestAmount:
        out.sort((a, b) {
          final aa = _dnum(a.data()['totalAmount']);
          final bb = _dnum(b.data()['totalAmount']);
          return bb.compareTo(aa);
        });
        break;
      case _SortOption.lowestAmount:
        out.sort((a, b) {
          final aa = _dnum(a.data()['totalAmount']);
          final bb = _dnum(b.data()['totalAmount']);
          return aa.compareTo(bb);
        });
        break;
    }
    return out;
  }

  ({int count, double total, double comm, double net}) _summary(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    var total = 0.0;
    var comm = 0.0;
    var net = 0.0;
    for (final d in docs) {
      final m = d.data();
      total += _dnum(m['totalAmount']);
      comm += _dnum(m['commissionAmount']);
      net += _dnum(m['ownerNet']);
    }
    return (count: docs.length, total: total, comm: comm, net: net);
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final fmt = NumberFormat.decimalPattern(_isAr ? 'ar' : 'en');

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        title: Text(_isAr ? 'الفواتير' : 'Invoices'),
        centerTitle: true,
      ),
      body: (user == null)
          ? Center(
              child: Text(_isAr ? 'سجّل الدخول أولاً' : 'Please sign in'),
            )
          : (_loadingRole
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: Builder(
                    builder: (context) {
                      if (_initialLoading && _docs.isEmpty) {
                        return ListView(
                          controller: _scroll,
                          padding: const EdgeInsets.all(16),
                          children: [
                            _FiltersHeader(
                              isAr: _isAr,
                              searchCtrl: _searchCtrl,
                              dateFilter: _dateFilter,
                              selectedMonth: _selectedMonth,
                              monthLabel: _monthFilterLabel(),
                              sort: _sort,
                              propertyFilterId: _propertyFilterId,
                              propertyOptions: const <String, String>{},
                              onDateChanged: _onDateFilterChanged,
                              onPickMonth: _pickMonth,
                              onClearMonthFilter: _clearMonthFilter,
                              onSortChanged: (v) => setState(() => _sort = v),
                              onPropertyChanged: (v) => setState(() => _propertyFilterId = v),
                            ),
                            const SizedBox(height: 12),
                            _SummaryCard(
                              isAr: _isAr,
                              currency: _currency,
                              count: 0,
                              total: 0,
                              commission: 0,
                              net: 0,
                              loading: true,
                            ),
                            const SizedBox(height: 12),
                            ...List<Widget>.generate(
                              6,
                              (_) => const _SkeletonInvoiceCard(),
                            ),
                          ],
                        );
                      }

                      if (_loadError != null && _docs.isEmpty) {
                        return ListView(
                          controller: _scroll,
                          padding: const EdgeInsets.all(16),
                          children: [
                            _FiltersHeader(
                              isAr: _isAr,
                              searchCtrl: _searchCtrl,
                              dateFilter: _dateFilter,
                              selectedMonth: _selectedMonth,
                              monthLabel: _monthFilterLabel(),
                              sort: _sort,
                              propertyFilterId: _propertyFilterId,
                              propertyOptions: const <String, String>{},
                              onDateChanged: _onDateFilterChanged,
                              onPickMonth: _pickMonth,
                              onClearMonthFilter: _clearMonthFilter,
                              onSortChanged: (v) => setState(() => _sort = v),
                              onPropertyChanged: (v) => setState(() => _propertyFilterId = v),
                            ),
                            const SizedBox(height: 12),
                            _ErrorRetryCard(
                              isAr: _isAr,
                              onRetry: _reload,
                            ),
                          ],
                        );
                      }

                      final visible = _visibleDocs();
                      final sum = _summary(visible);

                      final propertyOptions = <String, String>{};
                      for (final d in _docs) {
                        final pid = (d.data()['propertyId'] ?? '').toString().trim();
                        if (pid.isEmpty) continue;
                        propertyOptions[pid] = _propertyTitleCache[pid] ?? pid;
                      }

                      if (!_initialLoading && _docs.isEmpty) {
                        return ListView(
                          controller: _scroll,
                          padding: const EdgeInsets.all(16),
                          children: [
                            _FiltersHeader(
                              isAr: _isAr,
                              searchCtrl: _searchCtrl,
                              dateFilter: _dateFilter,
                              selectedMonth: _selectedMonth,
                              monthLabel: _monthFilterLabel(),
                              sort: _sort,
                              propertyFilterId: _propertyFilterId,
                              propertyOptions: propertyOptions,
                              onDateChanged: _onDateFilterChanged,
                              onPickMonth: _pickMonth,
                              onClearMonthFilter: _clearMonthFilter,
                              onSortChanged: (v) => setState(() => _sort = v),
                              onPropertyChanged: (v) => setState(() => _propertyFilterId = v),
                            ),
                            const SizedBox(height: 12),
                            _EmptyState(isAr: _isAr),
                          ],
                        );
                      }

                      return ListView.separated(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: visible.length + 1,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _FiltersHeader(
                                  isAr: _isAr,
                                  searchCtrl: _searchCtrl,
                                  dateFilter: _dateFilter,
                                  selectedMonth: _selectedMonth,
                                  monthLabel: _monthFilterLabel(),
                                  sort: _sort,
                                  propertyFilterId: _propertyFilterId,
                                  propertyOptions: propertyOptions,
                                  onDateChanged: _onDateFilterChanged,
                                  onPickMonth: _pickMonth,
                                  onClearMonthFilter: _clearMonthFilter,
                                  onSortChanged: (v) => setState(() => _sort = v),
                                  onPropertyChanged: (v) =>
                                      setState(() => _propertyFilterId = v),
                                ),
                                const SizedBox(height: 12),
                                _SummaryCard(
                                  isAr: _isAr,
                                  currency: _currency,
                                  count: sum.count,
                                  total: sum.total,
                                  commission: sum.comm,
                                  net: sum.net,
                                  loading: false,
                                ),
                              ],
                            );
                          }

                          final i = index - 1;
                          if (i >= visible.length) {
                            if (_loadError != null) {
                              return _ErrorRetryInline(
                                isAr: _isAr,
                                onRetry: _fetchNextPage,
                              );
                            }
                            if (_loadingMore) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }
                            if (!_hasMore) {
                              return const SizedBox(height: 2);
                            }
                            return const SizedBox(height: 2);
                          }

                          final doc = visible[i];
                          final m = doc.data();

                          final invoiceId =
                              (m['invoiceId'] ?? doc.id).toString().trim();
                          final bookingId =
                              (m['bookingId'] ?? '').toString().trim();
                          final propertyId =
                              (m['propertyId'] ?? '').toString().trim();
                          final fileUrl =
                              (m['fileUrl'] ?? m['pdfUrl'] ?? '').toString().trim();

                          final totalAmount = _dnum(m['totalAmount']);
                          final commissionAmount = _dnum(m['commissionAmount']);
                          final ownerNet = _dnum(m['ownerNet']);

                          final createdAt = _asDate(m['createdAt']);
                          final dateLabel = createdAt == null
                              ? '-'
                              : DateFormat.yMMMd(_isAr ? 'ar' : 'en_US')
                                  .format(createdAt);

                          final title = propertyId.isEmpty
                              ? (_isAr ? 'فاتورة' : 'Invoice')
                              : (_propertyTitleCache[propertyId] ?? propertyId);

                          return Card(
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(color: Colors.grey.shade300),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          title,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade50,
                                          borderRadius: BorderRadius.circular(20),
                                          border: Border.all(
                                            color: Colors.green.shade200,
                                          ),
                                        ),
                                        child: Text(
                                          _isAr ? 'مدفوعة' : 'PAID',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.green.shade800,
                                            letterSpacing: 0.4,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  _metaRow(_isAr ? 'التاريخ' : 'Date', dateLabel),
                                  const SizedBox(height: 6),
                                  _metaRow(
                                    _isAr ? 'الإجمالي' : 'Total',
                                    '${fmt.format(totalAmount)} $_currency',
                                  ),
                                  const SizedBox(height: 6),
                                  _metaRow(
                                    _isAr ? 'العمولة' : 'Commission',
                                    '${fmt.format(commissionAmount)} $_currency',
                                  ),
                                  const SizedBox(height: 6),
                                  _metaRow(
                                    _isAr ? 'الصافي' : 'Net',
                                    '${fmt.format(ownerNet)} $_currency',
                                  ),
                                  if (bookingId.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    _metaRow('bookingId', bookingId),
                                  ],
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: fileUrl.length > 12
                                          ? () {
                                              Navigator.of(context).push<void>(
                                                MaterialPageRoute<void>(
                                                  builder: (_) => InvoiceViewerPage(
                                                    invoiceUrl: fileUrl,
                                                  ),
                                                ),
                                              );
                                            }
                                          : null,
                                      icon: const Icon(Icons.picture_as_pdf_outlined),
                                      label: Text(
                                        _isAr ? 'عرض الفاتورة' : 'View Invoice',
                                      ),
                                    ),
                                  ),
                                  if (fileUrl.isEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      _isAr
                                          ? 'جاري تجهيز الفاتورة...'
                                          : 'Invoice is being prepared...',
                                      style: TextStyle(
                                        color: Colors.grey.shade700,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ],
                                  const SizedBox(height: 2),
                                  Text(
                                    'invoiceId: $invoiceId',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                )),
    );
  }

  static Widget _metaRow(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            k,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF333333),
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }
}

class _FiltersHeader extends StatelessWidget {
  const _FiltersHeader({
    required this.isAr,
    required this.searchCtrl,
    required this.dateFilter,
    required this.selectedMonth,
    required this.monthLabel,
    required this.sort,
    required this.propertyFilterId,
    required this.propertyOptions,
    required this.onDateChanged,
    required this.onPickMonth,
    required this.onClearMonthFilter,
    required this.onSortChanged,
    required this.onPropertyChanged,
  });

  final bool isAr;
  final TextEditingController searchCtrl;
  final _DateFilter dateFilter;
  final DateTime? selectedMonth;
  final String monthLabel;
  final _SortOption sort;
  final String propertyFilterId;
  final Map<String, String> propertyOptions;
  final ValueChanged<_DateFilter> onDateChanged;
  final VoidCallback onPickMonth;
  final VoidCallback onClearMonthFilter;
  final ValueChanged<_SortOption> onSortChanged;
  final ValueChanged<String> onPropertyChanged;

  String _dateLabel(_DateFilter f) {
    switch (f) {
      case _DateFilter.today:
        return isAr ? 'اليوم' : 'Today';
      case _DateFilter.last7:
        return isAr ? 'آخر 7 أيام' : 'Last 7 days';
      case _DateFilter.last30:
        return isAr ? 'آخر 30 يوم' : 'Last 30 days';
      case _DateFilter.all:
        return isAr ? 'الكل' : 'All';
      case _DateFilter.specificMonth:
        return isAr ? 'شهر محدد' : 'Specific month';
    }
  }

  String _sortLabel(_SortOption s) {
    switch (s) {
      case _SortOption.newest:
        return isAr ? 'الأحدث' : 'Newest';
      case _SortOption.highestAmount:
        return isAr ? 'الأعلى قيمة' : 'Highest amount';
      case _SortOption.lowestAmount:
        return isAr ? 'الأقل قيمة' : 'Lowest amount';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: searchCtrl,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: isAr ? 'بحث: bookingId أو اسم العقار' : 'Search: bookingId or property',
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _Dropdown<_DateFilter>(
                value: dateFilter,
                label: isAr ? 'الفترة' : 'Date',
                items: _DateFilter.values
                    .map(
                      (v) => DropdownMenuItem<_DateFilter>(
                        value: v,
                        child: Text(_dateLabel(v)),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  onDateChanged(v);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Dropdown<_SortOption>(
                value: sort,
                label: isAr ? 'الترتيب' : 'Sort',
                items: _SortOption.values
                    .map(
                      (v) => DropdownMenuItem<_SortOption>(
                        value: v,
                        child: Text(_sortLabel(v)),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  onSortChanged(v);
                },
              ),
            ),
          ],
        ),
        if (dateFilter == _DateFilter.specificMonth) ...[
          const SizedBox(height: 10),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              onTap: onPickMonth,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calendar_month_outlined, color: Colors.grey.shade700),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isAr ? 'الشهر' : 'Month',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            selectedMonth != null && monthLabel.isNotEmpty
                                ? monthLabel
                                : (isAr ? 'اضغط للاختيار' : 'Tap to select'),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF333333),
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: onClearMonthFilter,
                      child: Text(isAr ? 'مسح' : 'Clear'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        _Dropdown<String>(
          value: propertyFilterId,
          label: isAr ? 'العقار' : 'Property',
          items: <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(
              value: '',
              child: Text(isAr ? 'الكل' : 'All'),
            ),
            ...propertyOptions.entries.map(
              (e) => DropdownMenuItem<String>(
                value: e.key,
                child: Text(e.value),
              ),
            ),
          ],
          onChanged: (v) => onPropertyChanged(v ?? ''),
        ),
      ],
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.label,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final String label;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.isAr,
    required this.currency,
    required this.count,
    required this.total,
    required this.commission,
    required this.net,
    required this.loading,
  });

  final bool isAr;
  final String currency;
  final int count;
  final double total;
  final double commission;
  final double net;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern(isAr ? 'ar' : 'en');
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: loading
            ? const _SkeletonLineBlock()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.insights_outlined),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          isAr ? 'ملخص' : 'Summary',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _SummaryRow(
                    label: isAr ? 'عدد الفواتير' : 'Invoices',
                    value: '$count',
                  ),
                  const SizedBox(height: 6),
                  _SummaryRow(
                    label: isAr ? 'إجمالي المبالغ' : 'Total revenue',
                    value: '${fmt.format(total)} $currency',
                    strong: true,
                  ),
                  const SizedBox(height: 6),
                  _SummaryRow(
                    label: isAr ? 'إجمالي العمولة' : 'Total commission',
                    value: '${fmt.format(commission)} $currency',
                  ),
                  const SizedBox(height: 6),
                  _SummaryRow(
                    label: isAr ? 'إجمالي الصافي' : 'Total net',
                    value: '${fmt.format(net)} $currency',
                  ),
                ],
              ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.strong = false,
  });

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade700,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: strong ? 14 : 13,
            fontWeight: FontWeight.w900,
            color: strong ? cs.primary : const Color(0xFF333333),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isAr});
  final bool isAr;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined, size: 56, color: cs.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              isAr ? 'لا توجد فواتير' : 'No invoices',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              isAr ? 'عند إنشاء فاتورة ستظهر هنا.' : 'Your invoices will appear here.',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRetryCard extends StatelessWidget {
  const _ErrorRetryCard({required this.isAr, required this.onRetry});
  final bool isAr;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: cs.error.withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            Text(
              isAr ? 'تعذر تحميل الفواتير' : 'Could not load invoices',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onRetry,
                child: Text(isAr ? 'إعادة المحاولة' : 'Retry'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRetryInline extends StatelessWidget {
  const _ErrorRetryInline({required this.isAr, required this.onRetry});
  final bool isAr;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text(isAr ? 'تحميل المزيد' : 'Load more'),
        ),
      ),
    );
  }
}

class _SkeletonInvoiceCard extends StatelessWidget {
  const _SkeletonInvoiceCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: const Padding(
        padding: EdgeInsets.all(14),
        child: _SkeletonLineBlock(),
      ),
    );
  }
}

class _SkeletonLineBlock extends StatelessWidget {
  const _SkeletonLineBlock();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w) => Container(
          height: 12,
          width: w,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bar(220),
        const SizedBox(height: 10),
        bar(140),
        const SizedBox(height: 8),
        bar(180),
        const SizedBox(height: 8),
        bar(160),
        const SizedBox(height: 14),
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ],
    );
  }
}

