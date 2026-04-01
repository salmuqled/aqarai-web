import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/invoice.dart';
import 'package:aqarai_app/pages/admin_invoice_detail_page.dart';
import 'package:aqarai_app/services/admin_invoices_service.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Admin-only: invoices list, filters, summary, paginated loading.
class AdminInvoicesPage extends StatefulWidget {
  const AdminInvoicesPage({super.key});

  static const Color navy = Color(0xFF0D2B4D);

  @override
  State<AdminInvoicesPage> createState() => _AdminInvoicesPageState();
}

class _AdminInvoicesPageState extends State<AdminInvoicesPage> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final TextEditingController _searchCtrl = TextEditingController();

  Future<bool> _adminGate = AuthService.isAdmin();
  Future<InvoiceGlobalSummary>? _summaryFuture;

  String? _serviceType;
  DateTime? _dateFromUtc;
  DateTime? _dateToInclusiveUtc;

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _items = [];
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _hasMore = true;
  bool _loadingList = false;
  bool _loadingMore = false;
  String? _listError;

  @override
  void initState() {
    super.initState();
    _summaryFuture = AdminInvoicesService.loadGlobalSummary(_db);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadInitial();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _retryGate() => setState(() => _adminGate = AuthService.isAdmin());

  bool _passesClient(Invoice inv) {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return inv.invoiceNumber.toLowerCase().contains(q) ||
        inv.companyName.toLowerCase().contains(q);
  }

  Future<void> _refreshSummaryAndList() async {
    setState(() {
      _summaryFuture = AdminInvoicesService.loadGlobalSummary(_db);
    });
    await _loadInitial();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _items.clear();
      _lastDoc = null;
      _hasMore = true;
      _loadingList = true;
      _listError = null;
    });
    try {
      await _appendUntilCount(AdminInvoicesService.targetRowsPerLoad);
    } catch (e) {
      _listError = e.toString();
    }
    if (mounted) {
      setState(() => _loadingList = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loadingList) return;
    setState(() => _loadingMore = true);
    try {
      await _appendUntilCount(_items.length + AdminInvoicesService.targetRowsPerLoad);
    } catch (e) {
      _listError = e.toString();
    }
    if (mounted) {
      setState(() => _loadingMore = false);
    }
  }

  /// Pulls Firestore batches until [targetCount] rows pass client filters or server ends.
  Future<void> _appendUntilCount(int targetCount) async {
    var guard = 0;
    while (_items.length < targetCount && _hasMore && guard < 40) {
      guard++;
      var q = AdminInvoicesService.baseQuery(
        _db,
        serviceType: _serviceType,
        createdFromKuwaitDayUtc: _dateFromUtc,
        createdToKuwaitDayInclusiveUtc: _dateToInclusiveUtc,
      ).limit(AdminInvoicesService.pageFetchBatch);

      if (_lastDoc != null) {
        q = q.startAfterDocument(_lastDoc!);
      }

      final snap = await q.get();
      if (snap.docs.isEmpty) {
        _hasMore = false;
        break;
      }

      _lastDoc = snap.docs.last;
      if (snap.docs.length < AdminInvoicesService.pageFetchBatch) {
        _hasMore = false;
      }

      for (final d in snap.docs) {
        final inv = Invoice.fromFirestore(d);
        if (!_passesClient(inv)) continue;
        _items.add(d);
        if (_items.length >= targetCount) break;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null) return;
    final kuwaitCivil = DateTime.utc(picked.year, picked.month, picked.day);
    setState(() {
      if (isFrom) {
        _dateFromUtc = kuwaitCivil;
      } else {
        _dateToInclusiveUtc = kuwaitCivil;
      }
    });
  }

  void _clearFilters() {
    setState(() {
      _serviceType = null;
      _dateFromUtc = null;
      _dateToInclusiveUtc = null;
      _searchCtrl.clear();
    });
    _loadInitial();
  }

  void _applyFilters() {
    _loadInitial();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';

    return FutureBuilder<bool>(
      future: _adminGate,
      builder: (context, gate) {
        if (gate.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.adminInvoicesTitle)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (gate.data != true) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.adminInvoicesTitle)),
            body: _AccessDenied(isAr: isAr, onRetry: _retryGate),
          );
        }

        return Scaffold(
          backgroundColor: const Color(0xFFF7F7F7),
          appBar: AppBar(
            title: Text(loc.adminInvoicesTitle),
            backgroundColor: AdminInvoicesPage.navy,
            foregroundColor: Colors.white,
          ),
          body: RefreshIndicator(
            color: AdminInvoicesPage.navy,
            onRefresh: _refreshSummaryAndList,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: FutureBuilder<InvoiceGlobalSummary>(
                      future: _summaryFuture,
                      builder: (context, sumSnap) {
                        if (sumSnap.connectionState == ConnectionState.waiting) {
                          return const SizedBox(
                            height: 100,
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final s = sumSnap.data;
                        if (s == null) {
                          return const SizedBox.shrink();
                        }
                        return _SummaryRow(
                          summary: s,
                          loc: loc,
                          isAr: isAr,
                        );
                      },
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _FilterPanel(
                  loc: loc,
                  serviceType: _serviceType,
                  onServiceType: (v) => setState(() => _serviceType = v),
                  searchCtrl: _searchCtrl,
                  dateFrom: _dateFromUtc,
                  dateTo: _dateToInclusiveUtc,
                  onPickFrom: () => _pickDate(isFrom: true),
                  onPickTo: () => _pickDate(isFrom: false),
                  onApply: _applyFilters,
                  onClear: _clearFilters,
                )),
                if (_listError != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _listError!,
                        style: TextStyle(color: Colors.red.shade800),
                      ),
                    ),
                  ),
                if (_searchCtrl.text.trim().isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        loc.adminInvoicesClientFilterHint,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade700,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ),
                if (_loadingList && _items.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (!_loadingList && _items.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        loc.adminInvoicesEmpty,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          if (index >= _items.length) {
                            return const SizedBox.shrink();
                          }
                          final d = _items[index];
                          final inv = Invoice.fromFirestore(d);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _InvoiceCard(
                              inv: inv,
                              isAr: isAr,
                              loc: loc,
                              onTap: () {
                                Navigator.push<void>(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => AdminInvoiceDetailPage(
                                      invoiceId: d.id,
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                        childCount: _items.length,
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    child: Center(
                      child: _hasMore
                          ? TextButton.icon(
                              onPressed: _loadingMore ? null : _loadMore,
                              icon: _loadingMore
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.expand_more),
                              label: Text(loc.adminInvoicesLoadMore),
                            )
                          : Text(
                              loc.adminInvoicesEndOfList,
                              style: TextStyle(color: Colors.grey.shade500),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.summary,
    required this.loc,
    required this.isAr,
  });

  final InvoiceGlobalSummary summary;
  final AppLocalizations loc;
  final bool isAr;

  String _fmt(num n) {
    final x = n.toDouble();
    final s = x == x.roundToDouble() ? x.toStringAsFixed(0) : x.toStringAsFixed(2);
    return isAr ? '$s د.ك' : '$s KWD';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SummaryCard(
            label: loc.adminInvoicesSummaryTotalRevenue,
            value: _fmt(summary.totalRevenueKwd),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryCard(
            label: loc.adminInvoicesSummaryLedgerEntries,
            value: '${summary.ledgerEntryCount}',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SummaryCard(
            label: loc.adminInvoicesSummaryThisMonth,
            value: _fmt(summary.thisMonthRevenueKwd),
          ),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AdminInvoicesPage.navy,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.loc,
    required this.serviceType,
    required this.onServiceType,
    required this.searchCtrl,
    required this.dateFrom,
    required this.dateTo,
    required this.onPickFrom,
    required this.onPickTo,
    required this.onApply,
    required this.onClear,
  });

  final AppLocalizations loc;
  final String? serviceType;
  final ValueChanged<String?> onServiceType;
  final TextEditingController searchCtrl;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final VoidCallback onPickFrom;
  final VoidCallback onPickTo;
  final VoidCallback onApply;
  final VoidCallback onClear;

  String _fmtDay(DateTime? d) {
    if (d == null) return '—';
    return DateFormat.yMMMd().format(DateTime(d.year, d.month, d.day));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: searchCtrl,
                decoration: InputDecoration(
                  labelText: loc.adminInvoicesSearchHint,
                  prefixIcon: const Icon(Icons.search, size: 22),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => onApply(),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: ValueKey<String?>(serviceType),
                // ignore: deprecated_member_use
                value: serviceType,
                decoration: InputDecoration(
                  labelText: loc.adminInvoicesFilterServiceType,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(loc.adminInvoicesFilterAllServices),
                  ),
                  DropdownMenuItem(
                    value: InvoiceServiceType.rent,
                    child: Text(loc.adminInvoicesServiceRent),
                  ),
                  DropdownMenuItem(
                    value: InvoiceServiceType.sale,
                    child: Text(loc.adminInvoicesServiceSale),
                  ),
                  DropdownMenuItem(
                    value: InvoiceServiceType.chalet,
                    child: Text(loc.adminInvoicesServiceChalet),
                  ),
                ],
                onChanged: onServiceType,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onPickFrom,
                      child: Text(
                        '${loc.adminInvoicesDateFrom}\n${_fmtDay(dateFrom)}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onPickTo,
                      child: Text(
                        '${loc.adminInvoicesDateTo}\n${_fmtDay(dateTo)}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AdminInvoicesPage.navy,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: onApply,
                      child: Text(loc.adminInvoicesApplyFilters),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: onClear,
                    child: Text(loc.adminInvoicesClearFilters),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InvoiceCard extends StatelessWidget {
  const _InvoiceCard({
    required this.inv,
    required this.isAr,
    required this.loc,
    required this.onTap,
  });

  final Invoice inv;
  final bool isAr;
  final AppLocalizations loc;
  final VoidCallback onTap;

  String _fmtKwd(double n) {
    final s = n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(3);
    return isAr ? '$s د.ك' : '$s KWD';
  }

  @override
  Widget build(BuildContext context) {
    final dateStr = inv.createdAt != null
        ? DateFormat.yMMMd().format(inv.createdAt!.toDate())
        : '—';

    final st = inv.displayStatus;
    final Color chipBg;
    final Color chipFg;
    switch (st) {
      case InvoiceLifecycleStatus.paid:
        chipBg = const Color(0xFFE6F4EA);
        chipFg = const Color(0xFF1B5E20);
        break;
      case InvoiceLifecycleStatus.cancelled:
        chipBg = const Color(0xFFF3E8E8);
        chipFg = const Color(0xFFB71C1C);
        break;
      default:
        chipBg = const Color(0xFFFFF4E5);
        chipFg = const Color(0xFFB45309);
    }

    final emailLabel = inv.emailSent == true
        ? loc.adminInvoiceEmailSentYes
        : inv.emailSent == false
            ? loc.adminInvoiceEmailSentNo
            : '—';

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      inv.invoiceNumber,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AdminInvoicesPage.navy,
                      ),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: chipBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      st.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: chipFg,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                inv.companyName,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
              const SizedBox(height: 12),
              _metaRow(loc.adminInvoiceFieldAmount, _fmtKwd(inv.amount)),
              const SizedBox(height: 6),
              _metaRow(loc.adminInvoiceFieldArea, inv.area),
              const SizedBox(height: 6),
              _metaRow(loc.adminInvoiceFieldServiceType, inv.serviceType),
              const SizedBox(height: 6),
              _metaRow(loc.adminInvoiceFieldDate, dateStr),
              const SizedBox(height: 6),
              _metaRow(loc.adminInvoiceFieldEmailSent, emailLabel),
              if (inv.pdfError != null && inv.pdfError!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${loc.adminInvoiceFieldPdfError}: ${inv.pdfError}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.red.shade800,
                    height: 1.25,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static Widget _metaRow(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            k,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
        ),
      ],
    );
  }
}

class _AccessDenied extends StatelessWidget {
  const _AccessDenied({required this.isAr, required this.onRetry});

  final bool isAr;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(isAr ? 'غير مصرّح' : 'Not authorized'),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: Text(isAr ? 'إعادة' : 'Retry')),
          ],
        ),
      ),
    );
  }
}
