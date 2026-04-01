// DropdownButtonFormField still uses `value` for controlled updates (vs one-shot initialValue).
// ignore_for_file: deprecated_member_use

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/company_payment.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/company_payments_service.dart';

/// Admin-only: append a row to `company_payments` (bank / check / cash).
class AddCompanyPaymentPage extends StatefulWidget {
  const AddCompanyPaymentPage({super.key});

  @override
  State<AddCompanyPaymentPage> createState() => _AddCompanyPaymentPageState();
}

class _AddCompanyPaymentPageState extends State<AddCompanyPaymentPage> {
  final _formKey = GlobalKey<FormState>();
  final _amountCtrl = TextEditingController();
  final _referenceCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _db = FirebaseFirestore.instance;

  Future<bool> _adminGate = AuthService.isAdmin();

  String _type = CompanyPaymentType.other;
  String _reason = CompanyPaymentReason.sale;
  String _source = CompanyPaymentSource.bankTransfer;
  String _status = CompanyPaymentStatus.confirmed;
  String? _relatedAuctionId;
  String? _relatedDealId;
  bool _saving = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _referenceCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _onTypeChanged(String? v) {
    if (v == null) return;
    setState(() {
      _type = v;
      _relatedAuctionId = null;
      _relatedDealId = null;
    });
  }

  String _typeLabel(AppLocalizations loc, String v) {
    switch (v) {
      case CompanyPaymentType.auctionFee:
        return loc.companyPaymentTypeAuctionFee;
      case CompanyPaymentType.commission:
        return loc.companyPaymentTypeCommission;
      case CompanyPaymentType.other:
        return loc.companyPaymentTypeOther;
      default:
        return v;
    }
  }

  String _reasonLabel(AppLocalizations loc, String v) {
    switch (v) {
      case CompanyPaymentReason.sale:
        return loc.companyPaymentReasonSale;
      case CompanyPaymentReason.rent:
        return loc.companyPaymentReasonRent;
      case CompanyPaymentReason.auction:
        return loc.companyPaymentReasonAuction;
      case CompanyPaymentReason.managementFee:
        return loc.companyPaymentReasonManagementFee;
      case CompanyPaymentReason.other:
        return loc.companyPaymentReasonOther;
      default:
        return v;
    }
  }

  String _sourceLabel(AppLocalizations loc, String v) {
    switch (v) {
      case CompanyPaymentSource.bankTransfer:
        return loc.companyPaymentSourceBank;
      case CompanyPaymentSource.certifiedCheck:
        return loc.companyPaymentSourceCheck;
      case CompanyPaymentSource.cash:
        return loc.companyPaymentSourceCash;
      default:
        return v;
    }
  }

  String _statusLabel(AppLocalizations loc, String v) {
    switch (v) {
      case CompanyPaymentStatus.pending:
        return loc.companyPaymentStatusPending;
      case CompanyPaymentStatus.confirmed:
        return loc.companyPaymentStatusConfirmed;
      case CompanyPaymentStatus.rejected:
        return loc.companyPaymentStatusRejected;
      default:
        return v;
    }
  }

  String _shortAuctionSubtitle(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final fee = d.data()['auctionFee'];
    final id = d.id;
    final head = id.length <= 10 ? id : '${id.substring(0, 10)}…';
    return '$head · $fee KWD';
  }

  String _shortDealSubtitle(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final c = d.data()['commissionAmount'];
    final id = d.id;
    final head = id.length <= 10 ? id : '${id.substring(0, 10)}…';
    return '$head · ${c ?? '—'} KWD';
  }

  Future<void> _submit(AppLocalizations loc) async {
    if (!_formKey.currentState!.validate()) return;

    final amount = double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.companyPaymentErrAmount)),
      );
      return;
    }

    late final String relatedType;
    String? relatedId;
    if (_type == CompanyPaymentType.auctionFee) {
      relatedType = CompanyPaymentRelatedType.auctionRequest;
      relatedId = _relatedAuctionId;
      if (relatedId == null || relatedId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.companyPaymentErrAuction)),
        );
        return;
      }
    } else if (_type == CompanyPaymentType.commission) {
      relatedType = CompanyPaymentRelatedType.deal;
      relatedId = _relatedDealId;
      if (relatedId == null || relatedId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.companyPaymentErrDeal)),
        );
        return;
      }
    } else {
      relatedType = CompanyPaymentRelatedType.manual;
      relatedId = null;
    }

    setState(() => _saving = true);
    try {
      await CompanyPaymentsService.addPayment(
        db: _db,
        amount: amount,
        status: _status,
        type: _type,
        reason: _reason,
        source: _source,
        relatedType: relatedType,
        relatedId: relatedId,
        notes: _notesCtrl.text.trim(),
        referenceNumber: _source == CompanyPaymentSource.cash
            ? null
            : _referenceCtrl.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.companyPaymentSaved)),
      );
      Navigator.pop(context);
    } on DuplicateCompanyPaymentReferenceException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.companyPaymentErrDuplicateReference)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${loc.companyPaymentErrGeneric} ($e)')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return FutureBuilder<bool>(
      future: _adminGate,
      builder: (context, gate) {
        if (gate.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.companyPaymentAddTitle)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        if (gate.data != true) {
          return Scaffold(
            appBar: AppBar(title: Text(loc.companyPaymentAddTitle)),
            body: Center(
              child: FilledButton(
                onPressed: () => setState(() => _adminGate = AuthService.isAdmin()),
                child: const Text('Retry'),
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(loc.companyPaymentAddTitle),
            backgroundColor: AppColors.navy,
            foregroundColor: Colors.white,
          ),
          body: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TextFormField(
                  controller: _amountCtrl,
                  decoration: InputDecoration(
                    labelText: loc.companyPaymentAmountLabel,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (s) {
                    final v = double.tryParse((s ?? '').trim().replaceAll(',', '.'));
                    if (v == null || v <= 0) return loc.companyPaymentErrAmount;
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _type,
                  decoration: InputDecoration(
                    labelText: loc.companyPaymentTypeLabel,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final v in CompanyPaymentType.values)
                      DropdownMenuItem(
                        value: v,
                        child: Text(_typeLabel(loc, v)),
                      ),
                  ],
                  onChanged: _onTypeChanged,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _reason,
                  decoration: InputDecoration(
                    labelText: loc.companyPaymentReasonLabel,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final v in CompanyPaymentReason.values)
                      DropdownMenuItem(
                        value: v,
                        child: Text(_reasonLabel(loc, v)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _reason = v ?? _reason),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _source,
                  decoration: InputDecoration(
                    labelText: loc.companyPaymentSourceLabel,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final v in CompanyPaymentSource.values)
                      DropdownMenuItem(
                        value: v,
                        child: Text(_sourceLabel(loc, v)),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _source = v ?? _source;
                      if (_source == CompanyPaymentSource.cash) {
                        _referenceCtrl.clear();
                      }
                    });
                  },
                ),
                if (_source != CompanyPaymentSource.cash) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('company_payment_reference'),
                    controller: _referenceCtrl,
                    decoration: InputDecoration(
                      labelText: loc.companyPaymentReferenceLabel,
                      border: const OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    validator: (s) {
                      if (_source == CompanyPaymentSource.cash) return null;
                      if ((s ?? '').trim().isEmpty) {
                        return loc.companyPaymentErrReferenceRequired;
                      }
                      return null;
                    },
                  ),
                ],
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _status,
                  decoration: InputDecoration(
                    labelText: loc.companyPaymentStatusLabel,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final v in CompanyPaymentStatus.values)
                      DropdownMenuItem(
                        value: v,
                        child: Text(_statusLabel(loc, v)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _status = v ?? _status),
                ),
                const SizedBox(height: 20),
                if (_type == CompanyPaymentType.auctionFee) ...[
                  Text(
                    loc.companyPaymentRelatedLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: CompanyPaymentsService.recentPaidAuctionRequestsForPicker(
                      _db,
                    ).snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Text('${snap.error}');
                      }
                      if (!snap.hasData) {
                        return const LinearProgressIndicator(minHeight: 3);
                      }
                      final docs = snap.data!.docs;
                      if (docs.isEmpty) {
                        return Text(loc.companyPaymentNoAuctionOptions);
                      }
                      return DropdownButtonFormField<String>(
                        value: _relatedAuctionId,
                        decoration: InputDecoration(
                          labelText: loc.companyPaymentPickAuction,
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          for (final d in docs)
                            DropdownMenuItem(
                              value: d.id,
                              child: Text(
                                _shortAuctionSubtitle(d),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _relatedAuctionId = v),
                      );
                    },
                  ),
                ],
                if (_type == CompanyPaymentType.commission) ...[
                  Text(
                    loc.companyPaymentRelatedLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: CompanyPaymentsService.recentSoldDealsForPicker(
                      _db,
                    ).snapshots(),
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Text('${snap.error}');
                      }
                      if (!snap.hasData) {
                        return const LinearProgressIndicator(minHeight: 3);
                      }
                      final docs = snap.data!.docs;
                      if (docs.isEmpty) {
                        return Text(loc.companyPaymentNoDealOptions);
                      }
                      return DropdownButtonFormField<String>(
                        value: _relatedDealId,
                        decoration: InputDecoration(
                          labelText: loc.companyPaymentPickDeal,
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          for (final d in docs)
                            DropdownMenuItem(
                              value: d.id,
                              child: Text(
                                _shortDealSubtitle(d),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _relatedDealId = v),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  controller: _notesCtrl,
                  decoration: InputDecoration(
                    labelText: loc.companyPaymentNotesLabel,
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _saving ? null : () => _submit(loc),
                  child: _saving
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(loc.companyPaymentSave),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
