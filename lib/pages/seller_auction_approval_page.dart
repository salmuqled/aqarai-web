import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/widgets/auction/auction_lot_rejection_strip.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/services/auction/lot_service.dart';

/// Property owner: approve or reject the highest bid after the lot entered review.
class SellerAuctionApprovalPage extends StatefulWidget {
  const SellerAuctionApprovalPage({super.key, required this.lotId});

  final String lotId;

  @override
  State<SellerAuctionApprovalPage> createState() =>
      _SellerAuctionApprovalPageState();
}

class _SellerAuctionApprovalPageState extends State<SellerAuctionApprovalPage> {
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

  String _maskBidder(String? uid) {
    if (uid == null || uid.length < 4) {
      return _isAr ? 'مزايد مسجّل' : 'Registered bidder';
    }
    return _isAr
        ? 'مزايد ···${uid.substring(0, 4)}'
        : 'Bidder ···${uid.substring(0, 4)}';
  }

  Future<void> _submit(String decision) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await LotService.sellerApproveAuction(
        lotId: widget.lotId,
        decision: decision,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isAr ? 'تم حفظ ردك' : 'Your response was saved'),
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
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(
          _isAr ? 'اعتماد نتيجة المزاد' : 'Auction outcome',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: uid == null
          ? Center(
              child: Text(_isAr ? 'سجّل الدخول أولاً' : 'Sign in required'),
            )
          : StreamBuilder<AuctionLot?>(
              stream: LotService.watchLot(widget.lotId),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('${snap.error}'));
                }
                final lot = snap.data;
                if (lot == null) {
                  return const Center(child: CircularProgressIndicator());
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
                      AuctionLotRejectionStrip(
                        rejectionReason: lot.rejectionReason,
                      ),
                    ],
                  );
                }
                if (lot.status != LotStatus.pendingAdminReview) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _isAr
                            ? 'هذا العنصر ليس في مرحلة موافقة البائع.'
                            : 'This lot is not awaiting seller approval.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final high = lot.currentHighBid;
                final decided = lot.sellerApprovalStatus != null &&
                    lot.sellerApprovalStatus != LotSellerApprovalStatus.pending;
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
                                  : (_isAr ? '—' : '—'),
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _isAr ? 'المزايد' : 'Bidder',
                              style: TextStyle(color: Colors.grey.shade700),
                            ),
                            Text(
                              _maskBidder(lot.currentHighBidderId),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (decided)
                      Text(
                        _isAr
                            ? 'تم تسجيل ردّك مسبقاً.'
                            : 'You have already responded.',
                        textAlign: TextAlign.center,
                      )
                    else ...[
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _submit('approve'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(
                          _isAr ? '✔️ أوافق على السعر' : '✔️ I accept this price',
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
                        icon: const Icon(Icons.cancel_outlined),
                        label: Text(
                          _isAr ? '❌ أرفض' : '❌ I reject',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
    );
  }
}
