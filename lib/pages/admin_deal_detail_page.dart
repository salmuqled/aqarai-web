import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

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
  final _finalFocus = FocusNode();
  final _bookingFocus = FocusNode();
  final _svc = DealAdminService();
  final _priceFmt = NumberFormat.decimalPattern();

  String _serviceType = 'sale';
  bool _saving = false;
  Timestamp? _appliedRemoteAt;
  bool _hydratePending = false;

  @override
  void dispose() {
    _finalCtrl.dispose();
    _bookingCtrl.dispose();
    _finalFocus.dispose();
    _bookingFocus.dispose();
    super.dispose();
  }

  String _pipelineResolved(Map<String, dynamic> d) {
    final raw = d['dealStatus']?.toString().trim();
    if (raw != null && raw.isNotEmpty) return raw;
    return DealStatus.closed;
  }

  String _pipelineLabel(String code, bool isAr) {
    switch (code) {
      case DealStatus.newLead:
        return isAr ? 'جديد' : 'New';
      case DealStatus.contacted:
        return isAr ? 'تم التواصل' : 'Contacted';
      case DealStatus.qualified:
        return isAr ? 'مؤهل' : 'Qualified';
      case DealStatus.booked:
        return isAr ? 'محجوز' : 'Booked';
      case DealStatus.signed:
        return isAr ? 'موقّع' : 'Signed';
      case DealStatus.closed:
        return isAr ? 'مغلق' : 'Closed';
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
      final booking = double.tryParse(
            _bookingCtrl.text.replaceAll(',', '').trim(),
          ) ??
          0;
      if (booking >= 0) {
        await _svc.saveBookingAmount(
          dealId: widget.dealId,
          bookingAmount: booking,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.adminDealSaved)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onPipelineChange(
    String newStatus,
    AppLocalizations loc,
  ) async {
    try {
      await _svc.setPipelineStatus(
        dealId: widget.dealId,
        newStatus: newStatus,
      );
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

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final ref = FirebaseFirestore.instance.collection('deals').doc(widget.dealId);

    return Scaffold(
      appBar: AppBar(
        title: Text(loc.adminDealDetailTitle),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: ref.snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
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
              final fs = storedFinal == 0 ? '' : _priceFmt.format(storedFinal);
              final bs = bookingVal == 0 ? '' : _priceFmt.format(bookingVal);
              setState(() {
                _appliedRemoteAt = remoteUpd;
                _finalCtrl.text = fs;
                _bookingCtrl.text = bs;
              });
            });
          }

          final showFinancial =
              DealPipelineStatus.showFinalPriceSection(pipeline);
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
                                  child: Text(_pipelineLabel(s, isAr)),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            _onPipelineChange(v, loc);
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                '${loc.adminDealPropertyPrice}: ${_fmtPrice(propPrice)} KWD',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
                subtitle: !isFinalizedDeal(d)
                    ? Text(
                        isAr
                            ? 'يُفعّل بعد وضع الصفقة موقّعة أو مغلقة'
                            : 'Available when deal is signed or closed',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      )
                    : null,
                value: commissionPaid,
                onChanged: !isFinalizedDeal(d)
                    ? null
                    : (v) async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await _svc.setCommissionPaid(
                            dealId: widget.dealId,
                            paid: v,
                          );
                        } catch (e) {
                          if (!mounted) return;
                          messenger.showSnackBar(
                            SnackBar(content: Text('$e')),
                          );
                        }
                      },
              ),
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
