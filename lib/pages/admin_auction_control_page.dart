import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/models/auction/auction.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/services/auction/auction_service.dart';
import 'package:aqarai_app/services/auth_service.dart';
import 'package:aqarai_app/services/auction/lot_service.dart';
import 'package:aqarai_app/widgets/admin_auction/active_lot_control_section.dart';
import 'package:aqarai_app/widgets/admin_auction/auction_status_section.dart';
import 'package:aqarai_app/widgets/admin_auction/live_bids_monitor.dart';
import 'package:aqarai_app/widgets/admin_auction/logs_section.dart';
import 'package:aqarai_app/widgets/admin_auction/lot_list_section.dart';
import 'package:aqarai_app/widgets/admin_auction/user_control_section.dart';

/// Real-time admin control room for a single auction (lots, bids, bidders, logs).
class AdminAuctionControlPage extends StatefulWidget {
  const AdminAuctionControlPage({
    super.key,
    required this.auctionId,
  });

  final String auctionId;

  @override
  State<AdminAuctionControlPage> createState() =>
      _AdminAuctionControlPageState();
}

class _AdminAuctionControlPageState extends State<AdminAuctionControlPage> {
  Future<bool> _adminGate = AuthService.isAdmin();

  void _retryGate() {
    setState(() => _adminGate = AuthService.isAdmin());
  }

  AuctionLot? _activeLot(List<AuctionLot> lots) {
    for (final l in lots) {
      if (l.status == LotStatus.active) return l;
    }
    return null;
  }

  Future<void> _runGuarded(
    BuildContext context,
    bool isAr,
    Future<void> Function() fn,
  ) async {
    try {
      await fn();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isAr ? 'تم التنفيذ' : 'Done'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = Localizations.localeOf(context).languageCode == 'ar';
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'admin';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(isAr ? 'تحكم المزاد' : 'Auction control'),
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<bool>(
        future: _adminGate,
        builder: (context, gate) {
          if (gate.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (gate.data != true) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(isAr ? 'غير مصرّح' : 'Not authorized'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _retryGate,
                      child: Text(isAr ? 'إعادة المحاولة' : 'Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          return StreamBuilder<Auction?>(
            stream: AuctionService.watchAuction(widget.auctionId),
            builder: (context, aSnap) {
              if (aSnap.hasError) {
                return Center(child: Text('${aSnap.error}'));
              }
              if (!aSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final auction = aSnap.data;
              if (auction == null) {
                return Center(
                  child: Text(isAr ? 'المزاد غير موجود' : 'Auction not found'),
                );
              }

              return StreamBuilder<List<AuctionLot>>(
                stream: LotService.watchLotsForAdminAuction(widget.auctionId),
                builder: (context, lSnap) {
                  final lots = lSnap.data ?? [];
                  final active = _activeLot(lots);

                  Future<void> runJob(Future<void> Function() job) =>
                      _runGuarded(context, isAr, job);

                  return ListView(
                    children: [
                      AuctionStatusSection(
                        auction: auction,
                        adminUid: uid,
                        isArabic: isAr,
                        onAction: runJob,
                      ),
                      LotListSection(
                        auction: auction,
                        lots: lots,
                        adminUid: uid,
                        isArabic: isAr,
                        onAction: runJob,
                      ),
                      ActiveLotControlSection(
                        auction: auction,
                        activeLot: active,
                        adminUid: uid,
                        isArabic: isAr,
                        onAction: runJob,
                      ),
                      LiveBidsMonitor(
                        auctionId: widget.auctionId,
                        isArabic: isAr,
                      ),
                      if (active != null)
                        UserControlSection(
                          auction: auction,
                          activeLot: active,
                          adminUid: uid,
                          isArabic: isAr,
                          onAction: runJob,
                        ),
                      LogsSection(
                        auctionId: widget.auctionId,
                        isArabic: isAr,
                      ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
