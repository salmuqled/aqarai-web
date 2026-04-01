import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/widgets/auction/auction_lot_rejection_strip.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/services/auction/lot_service.dart';

/// Admin: approve or reject the deal after auction end (dual approval with seller).
class AdminAuctionDealReviewPage extends StatefulWidget {
  const AdminAuctionDealReviewPage({
    super.key,
    required this.lotId,
    required this.auctionId,
  });

  final String lotId;
  final String auctionId;

  @override
  State<AdminAuctionDealReviewPage> createState() =>
      _AdminAuctionDealReviewPageState();
}

class _AdminAuctionDealReviewPageState extends State<AdminAuctionDealReviewPage> {
  bool _busy = false;

  bool get _isAr {
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
    final suffix = _isAr ? ' د.ك' : ' KWD';
    return '${fmt.format(value)}$suffix';
  }

  Future<void> _submit(String decision) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await LotService.adminReviewAuction(
        lotId: widget.lotId,
        decision: decision,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isAr ? 'تم تنفيذ القرار' : 'Decision saved'),
          backgroundColor: Colors.green.shade700,
        ),
      );
      Navigator.of(context).pop();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? e.code),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(
          _isAr ? 'مراجعة صفقة المزاد' : 'Review auction deal',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: StreamBuilder<AuctionLot?>(
        stream: LotService.watchLot(widget.lotId),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          final lot = snap.data;
          if (lot == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (lot.auctionId != widget.auctionId) {
            return Center(
              child: Text(_isAr ? 'معرّف المزاد غير متطابق' : 'Auction id mismatch'),
            );
          }
          if (lot.status == LotStatus.rejected) {
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  lot.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy,
                  ),
                ),
                const SizedBox(height: 16),
                AuctionLotRejectionStrip(rejectionReason: lot.rejectionReason),
              ],
            );
          }
          if (lot.status != LotStatus.pendingAdminReview) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _isAr
                      ? 'هذا العنصر ليس قيد مراجعة الإدارة.'
                      : 'This lot is not pending admin review.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final pid = lot.propertyId?.trim();
          final high = lot.currentHighBid;
          final sellerSt = lot.sellerApprovalStatus;
          final adminOk = lot.adminApproved == true;

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                lot.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.navy,
                ),
              ),
              const SizedBox(height: 12),
              if (pid != null && pid.isNotEmpty)
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('properties')
                      .doc(pid)
                      .snapshots(),
                  builder: (context, pSnap) {
                    final d = pSnap.data?.data();
                    final title = d?['title']?.toString().trim() ?? '';
                    final area = d?['areaAr']?.toString().trim() ?? '';
                    return Card(
                      child: ListTile(
                        title: Text(
                          _isAr ? 'العقار' : 'Property',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        subtitle: Text(
                          title.isNotEmpty
                              ? '$title${area.isNotEmpty ? ' · $area' : ''}'
                              : pid,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _isAr ? 'أعلى مزايدة' : 'Highest bid',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        high != null && high > 0
                            ? _money(high)
                            : '—',
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isAr ? 'موافقة البائع' : 'Seller approval',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      Text(
                        sellerSt?.firestoreValue ??
                            (_isAr ? 'غير معروف' : 'unknown'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isAr ? 'اعتماد الإدارة (حالي)' : 'Admin approved (current)',
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      Text(
                        adminOk
                            ? (_isAr ? 'نعم' : 'Yes')
                            : (_isAr ? 'لا' : 'No'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (adminOk)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _isAr
                        ? 'تم تسجيل اعتمادك الإداري. إن اكتملت موافقة البائع تُغلق الصفقة تلقائياً.'
                        : 'Admin approval recorded. Sale completes when seller also approves.',
                    style: TextStyle(color: Colors.grey.shade800),
                  ),
                ),
              FilledButton.icon(
                onPressed: _busy || adminOk ? null : () => _submit('approve'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.verified_outlined),
                label: Text(
                  _isAr ? 'اعتماد الصفقة' : 'Approve deal',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _submit('reject'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red.shade800,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.block_outlined),
                label: Text(
                  _isAr ? 'رفض الصفقة' : 'Reject deal',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
