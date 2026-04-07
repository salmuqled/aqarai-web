import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'package:aqarai_app/constants/commission_payment_constants.dart';
import 'package:aqarai_app/constants/deal_constants.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/deal_pipeline.dart';
import 'package:aqarai_app/services/deal_admin_service.dart';
import 'package:aqarai_app/utils/financial_rules.dart';
import 'package:aqarai_app/widgets/property_details_page.dart';

/// Admin: final deal price, commission (from final price only), pipeline status.
class AdminDealDetailPage extends StatefulWidget {
  const AdminDealDetailPage({super.key, required this.dealId});

  final String dealId;

  @override
  State<AdminDealDetailPage> createState() => _AdminDealDetailPageState();
}

class _AdminDealDetailPageState extends State<AdminDealDetailPage> {
  final _finalCtrl = TextEditingController();
  final _bookingCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _finalFocus = FocusNode();
  final _bookingFocus = FocusNode();
  final _svc = DealAdminService();
  final _priceFmt = NumberFormat.decimalPattern();

  String _serviceType = 'sale';
  bool _saving = false;
  bool _noteSaving = false;
  bool _followUpSaving = false;
  bool _contactSaving = false;
  bool _markingCommissionPaid = false;
  Timestamp? _appliedRemoteAt;
  bool _hydratePending = false;

  @override
  void dispose() {
    _finalCtrl.dispose();
    _bookingCtrl.dispose();
    _noteCtrl.dispose();
    _finalFocus.dispose();
    _bookingFocus.dispose();
    super.dispose();
  }

  String _pipelineResolved(Map<String, dynamic> d) {
    final raw = d['dealStatus']?.toString().trim();
    if (raw != null && raw.isNotEmpty) return raw;
    return DealStatus.closed;
  }

  String _pipelineLabel(String code, AppLocalizations loc) {
    switch (code) {
      case DealStatus.newLead:
        return loc.adminDealPipelineNewLeads;
      case DealStatus.contacted:
        return loc.adminDealPipelineContacted;
      case DealStatus.qualified:
        return loc.adminDealPipelineQualified;
      case DealStatus.booked:
        return loc.adminDealPipelineBooked;
      case DealStatus.signed:
        return loc.adminDealPipelineSigned;
      case DealStatus.closed:
        return loc.adminDealPipelineClosed;
      case DealStatus.notInterested:
        return loc.adminDealPipelineNotInterested;
      default:
        return code;
    }
  }

  double _parseFinalFromField() {
    final t = _finalCtrl.text.replaceAll(',', '').trim();
    return double.tryParse(t) ?? 0;
  }

  double _previewCommission() {
    return DealCommissionCalculator.compute(
      finalPrice: _parseFinalFromField(),
      serviceType: _serviceType,
    );
  }

  Future<void> _saveFinancials(AppLocalizations loc) async {
    final fp = _parseFinalFromField();
    if (fp < 0) return;
    setState(() => _saving = true);
    try {
      await _svc.saveFinalPriceAndCommission(
        dealId: widget.dealId,
        finalPrice: fp,
      );
      final booking =
          double.tryParse(_bookingCtrl.text.replaceAll(',', '').trim()) ?? 0;
      if (booking >= 0) {
        await _svc.saveBookingAmount(
          dealId: widget.dealId,
          bookingAmount: booking,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.adminDealSaved)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _markLastContact(AppLocalizations loc) async {
    setState(() => _contactSaving = true);
    try {
      await _svc.markLastContactNow(dealId: widget.dealId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.adminDealContactMarked)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _contactSaving = false);
    }
  }

  Future<void> _saveNote(AppLocalizations loc) async {
    final text = _noteCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _noteSaving = true);
    try {
      await _svc.appendDealNote(dealId: widget.dealId, text: text);
      _noteCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.adminDealNoteSaved)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _noteSaving = false);
    }
  }

  Future<void> _saveFollowUpAt(DateTime at, AppLocalizations loc) async {
    setState(() => _followUpSaving = true);
    try {
      await _svc.setNextFollowUpAt(dealId: widget.dealId, at: at);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.adminDealFollowUpSaved)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _followUpSaving = false);
    }
  }

  Future<void> _pickAndSaveFollowUp(AppLocalizations loc) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (time == null || !mounted) return;
    final at = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    await _saveFollowUpAt(at, loc);
  }

  Future<void> _quickFollowUp(Duration offset, AppLocalizations loc) async {
    await _saveFollowUpAt(DateTime.now().add(offset), loc);
  }

  Future<void> _clearFollowUp(AppLocalizations loc) async {
    setState(() => _followUpSaving = true);
    try {
      await _svc.clearNextFollowUpAt(dealId: widget.dealId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.adminDealFollowUpCleared)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _followUpSaving = false);
    }
  }

  List<Map<String, dynamic>> _sortedNotes(Map<String, dynamic> d) {
    final raw = d['notes'];
    if (raw is! List) return [];
    final out = <Map<String, dynamic>>[];
    for (final e in raw) {
      if (e is Map) {
        out.add(Map<String, dynamic>.from(e));
      }
    }
    out.sort((a, b) {
      final ta = a['createdAt'];
      final tb = b['createdAt'];
      if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
      return 0;
    });
    return out;
  }

  String _formatTs(Timestamp ts) {
    final loc = Localizations.localeOf(context);
    return DateFormat.yMMMd(loc.toString()).add_jm().format(ts.toDate());
  }

  Future<void> _sharePaymentDetails(
    Map<String, dynamic> d,
    AppLocalizations loc,
  ) async {
    final comm = getCommission(d);
    if (comm <= 0) return;
    final amountStr = _priceFmt.format(comm);
    final text = loc.adminDealPaymentShareBody(
      kCommissionCollectionIban,
      amountStr,
    );
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _markCommissionReceivedAndClose(AppLocalizations loc) async {
    setState(() => _markingCommissionPaid = true);
    try {
      await _svc.markCommissionReceivedAndClose(dealId: widget.dealId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(loc.adminDealSaved)));
      }
    } on StateError catch (e) {
      if (!mounted) return;
      final msg = switch (e.message) {
        'commission_collect_invalid_status' =>
          loc.adminDealCommissionCollectInvalidStatus,
        'commission_already_paid' => loc.adminDealCommissionAlreadyPaid,
        'commission_not_confirmed_in_ledger' =>
          loc.adminDealCommissionNotInLedger,
        _ => e.message,
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _markingCommissionPaid = false);
    }
  }

  Future<void> _onPipelineChange(String newStatus, AppLocalizations loc) async {
    try {
      await _svc.setPipelineStatus(dealId: widget.dealId, newStatus: newStatus);
    } on StateError catch (e) {
      if (!mounted) return;
      final msg = e.message == 'final_price_required'
          ? loc.adminDealFinalPriceRequired
          : e.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Signed requires a positive final price — collect it here before updating status.
  Future<void> _presentSignedPriceSheet(
    AppLocalizations loc,
    double storedFinal,
  ) async {
    final ctrl = TextEditingController(
      text: storedFinal > 0 ? _priceFmt.format(storedFinal) : '',
    );
    var saving = false;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        loc.adminDealSignedPriceSheetTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: ctrl,
                        autofocus: storedFinal <= 0,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[\d\.,]')),
                        ],
                        decoration: InputDecoration(
                          hintText: loc.adminDealSignedPriceHint,
                          border: const OutlineInputBorder(),
                          suffixText: 'KWD',
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: saving
                                  ? null
                                  : () => Navigator.of(sheetContext).pop(),
                              child: Text(loc.cancel),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: saving
                                  ? null
                                  : () async {
                                      FocusScope.of(sheetContext).unfocus();
                                      final raw =
                                          ctrl.text.replaceAll(',', '').trim();
                                      final fp = double.tryParse(raw) ?? 0;
                                      if (raw.isEmpty || fp <= 0) {
                                        if (!sheetContext.mounted) return;
                                        ScaffoldMessenger.of(
                                          sheetContext,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              loc.adminDealFinalPriceRequired,
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      setModalState(() => saving = true);
                                      try {
                                        await _svc.saveFinalPriceAndCommission(
                                          dealId: widget.dealId,
                                          finalPrice: fp,
                                        );
                                        await _svc.setPipelineStatus(
                                          dealId: widget.dealId,
                                          newStatus: DealStatus.signed,
                                        );
                                        if (sheetContext.mounted) {
                                          Navigator.of(sheetContext).pop();
                                        }
                                        if (mounted) {
                                          ScaffoldMessenger.of(
                                            this.context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(loc.adminDealSaved),
                                            ),
                                          );
                                        }
                                      } on StateError catch (e) {
                                        if (!mounted) return;
                                        final msg =
                                            e.message == 'final_price_required'
                                                ? loc.adminDealFinalPriceRequired
                                                : e.message;
                                        ScaffoldMessenger.of(
                                          this.context,
                                        ).showSnackBar(
                                          SnackBar(content: Text(msg)),
                                        );
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(
                                            this.context,
                                          ).showSnackBar(
                                            SnackBar(content: Text('$e')),
                                          );
                                        }
                                      } finally {
                                        if (sheetContext.mounted) {
                                          setModalState(() => saving = false);
                                        }
                                      }
                                    },
                              child: saving
                                  ? const SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(loc.confirm),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      );
    } finally {
      ctrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final ref = FirebaseFirestore.instance
        .collection('deals')
        .doc(widget.dealId);

    return Scaffold(
      appBar: AppBar(title: Text(loc.adminDealDetailTitle)),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: ref.snapshots(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('${snap.error}'));
            }
            final doc = snap.data;
            if (doc == null || !doc.exists) {
              return Center(
                child: Text(isAr ? 'الصفقة غير موجودة' : 'Deal not found'),
              );
            }
            final d = doc.data()!;
            final pipeline = _pipelineResolved(d);
            _serviceType = DealCommissionCalculator.normalizeServiceType(d);

            final propPrice = d['propertyPrice'] ?? d['listingPrice'];
            final storedFinal = (d['finalPrice'] is num)
                ? (d['finalPrice'] as num).toDouble()
                : double.tryParse('${d['finalPrice'] ?? 0}') ?? 0;
            final storedComm = getCommission(d);
            final bookingVal = (d['bookingAmount'] is num)
                ? (d['bookingAmount'] as num).toDouble()
                : double.tryParse('${d['bookingAmount'] ?? 0}') ?? 0;
            final commissionPaid = isPaid(d);
            final propertyId = d['propertyId']?.toString() ?? '';
            final title = (d['propertyTitle'] ?? d['title'] ?? '').toString();

            final remoteUpd = d['updatedAt'] ?? d['createdAt'];
            if (remoteUpd is Timestamp &&
                remoteUpd != _appliedRemoteAt &&
                !_finalFocus.hasFocus &&
                !_bookingFocus.hasFocus &&
                !_hydratePending) {
              _hydratePending = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _hydratePending = false;
                if (!mounted) return;
                final fs = storedFinal == 0
                    ? ''
                    : _priceFmt.format(storedFinal);
                final bs = bookingVal == 0 ? '' : _priceFmt.format(bookingVal);
                setState(() {
                  _appliedRemoteAt = remoteUpd;
                  _finalCtrl.text = fs;
                  _bookingCtrl.text = bs;
                });
              });
            }

            final showFinancial = DealPipelineStatus.showFinalPriceSection(
              pipeline,
            );
            final serviceLabel = _serviceType == 'rent'
                ? loc.adminDealServiceRent
                : loc.adminDealServiceSale;

            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (title.isNotEmpty)
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  '${isAr ? "نوع التعامل" : "Service type"}: $serviceLabel',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(loc.adminDealPipelineStatus),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: pipeline,
                            isExpanded: true,
                            items: DealPipelineStatus.ordered
                                .map(
                                  (s) => DropdownMenuItem(
                                    value: s,
                                    child: Text(_pipelineLabel(s, loc)),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) {
                              if (v == null) return;
                              if (v == DealStatus.signed) {
                                _presentSignedPriceSheet(loc, storedFinal);
                              } else {
                                _onPipelineChange(v, loc);
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _contactSaving
                      ? null
                      : () => _markLastContact(loc),
                  icon: _contactSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.phone_callback_outlined),
                  label: Text(loc.adminDealMarkContacted),
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    loc.adminDealFollowUpDateLabel,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  d['nextFollowUpAt'] is Timestamp
                      ? _formatTs(d['nextFollowUpAt'] as Timestamp)
                      : loc.adminDealFollowUpNotSet,
                  style: TextStyle(color: Colors.grey.shade800),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _followUpSaving
                          ? null
                          : () =>
                                _quickFollowUp(const Duration(minutes: 5), loc),
                      icon: const Icon(Icons.snooze_outlined),
                      label: Text(loc.adminDealFollowUpIn5Minutes),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _followUpSaving
                          ? null
                          : () => _quickFollowUp(
                              const Duration(minutes: 30),
                              loc,
                            ),
                      icon: const Icon(Icons.schedule_outlined),
                      label: Text(loc.adminDealFollowUpIn30Minutes),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _followUpSaving
                          ? null
                          : () => _pickAndSaveFollowUp(loc),
                      icon: _followUpSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.event_outlined),
                      label: Text(loc.adminDealPickFollowUpDateTime),
                    ),
                    if (d['nextFollowUpAt'] is Timestamp)
                      TextButton(
                        onPressed: _followUpSaving
                            ? null
                            : () => _clearFollowUp(loc),
                        child: Text(loc.adminDealClearFollowUp),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    loc.adminDealNotesSectionTitle,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _noteCtrl,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: loc.adminDealAddNoteHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton.icon(
                    onPressed: _noteSaving ? null : () => _saveNote(loc),
                    icon: _noteSaving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(loc.adminDealSaveNote),
                  ),
                ),
                ..._sortedNotes(d).map((n) {
                  final text = n['text']?.toString() ?? '';
                  final ca = n['createdAt'];
                  final sub = ca is Timestamp ? _formatTs(ca) : '';
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Material(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (sub.isNotEmpty)
                              Text(
                                sub,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            if (sub.isNotEmpty) const SizedBox(height: 6),
                            Text(text),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 20),
                Text(
                  '${loc.adminDealPropertyPrice}: ${_fmtPrice(propPrice)} KWD',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                if (showFinancial) ...[
                  TextField(
                    controller: _finalCtrl,
                    focusNode: _finalFocus,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[\d\.,]')),
                    ],
                    decoration: InputDecoration(
                      labelText: loc.adminDealFinalPrice,
                      border: const OutlineInputBorder(),
                      suffixText: 'KWD',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: () => setState(() {}),
                        child: Text(loc.adminDealCalculateCommission),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${loc.adminDealCommission}: ${_priceFmt.format(_parseFinalFromField() > 0 ? _previewCommission() : (storedComm > 0 ? storedComm : _previewCommission()))} KWD',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isAr
                        ? 'العمولة تُحسب من سعر الاتفاق النهائي فقط (بيع ١٪ • إيجار نصف المبلغ المدخل إذا كان يمثل شهراً).'
                        : 'Commission uses final deal price only (sale 1% • rent: half of entered amount if one period).',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _bookingCtrl,
                    focusNode: _bookingFocus,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[\d\.,]')),
                    ],
                    decoration: InputDecoration(
                      labelText: loc.adminDealBookingAmount,
                      border: const OutlineInputBorder(),
                      suffixText: 'KWD',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _saving ? null : () => _saveFinancials(loc),
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save),
                    label: Text(loc.adminDealSaveFinancials),
                  ),
                ],
                const SizedBox(height: 24),
                SwitchListTile(
                  title: Text(loc.adminDealCommissionPaid),
                  subtitle: Text(
                    !isFinalizedDeal(d)
                        ? loc.adminDealCommissionPaidLockedHint
                        : loc.adminDealCommissionPaidFromLedgerHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  value: commissionPaid,
                  onChanged: null,
                ),
                if (isFinalizedDeal(d)) ...[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: getCommission(d) > 0
                        ? () => _sharePaymentDetails(d, loc)
                        : null,
                    icon: const Icon(Icons.share_outlined),
                    label: Text(loc.adminDealSendPaymentDetails),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: isFinalizedDeal(d) &&
                            (d['dealStatus'] ?? '').toString().trim() !=
                                DealStatus.closed &&
                            !_markingCommissionPaid
                        ? () => _markCommissionReceivedAndClose(loc)
                        : null,
                    icon: _markingCommissionPaid
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.payments_outlined),
                    label: Text(loc.adminDealMarkCommissionReceived),
                  ),
                ],
                if (propertyId.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => PropertyDetailsPage(
                            propertyId: propertyId,
                            isAdminView: true,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: Text(loc.adminDealOpenListing),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  String _fmtPrice(dynamic raw) {
    final n = _parseNum(raw);
    return n == null ? '${raw ?? '—'}' : _priceFmt.format(n);
  }

  num? _parseNum(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    return num.tryParse(v.toString().trim());
  }
}
