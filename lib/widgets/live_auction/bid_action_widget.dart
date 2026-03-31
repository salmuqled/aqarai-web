import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:aqarai_app/app/app_theme.dart';
import 'package:aqarai_app/l10n/app_localizations.dart';
import 'package:aqarai_app/models/auction/auction_enums.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/models/auction/auction_participant.dart';
import 'package:aqarai_app/models/auction/auction_deposit.dart';
import 'package:aqarai_app/models/auction/lot_permission.dart';
import 'package:aqarai_app/services/auction/auction_service.dart';
import 'package:aqarai_app/services/auction/bid_service.dart';
import 'package:aqarai_app/services/auction/deposit_service.dart';
import 'package:aqarai_app/services/auction/permission_service.dart';

/// Bidding UI: eligibility from live Firestore + [BidService.placeBid] only.
class BidActionWidget extends StatefulWidget {
  const BidActionWidget({
    super.key,
    required this.auctionId,
    required this.lotId,
    required this.lot,
    required this.serverNow,
  });

  final String auctionId;
  final String lotId;
  final AuctionLot lot;
  /// NTP-adjusted “now” from parent (tick every second).
  final DateTime serverNow;

  @override
  State<BidActionWidget> createState() => _BidActionWidgetState();
}

class _BidActionWidgetState extends State<BidActionWidget> {
  final TextEditingController _amountController = TextEditingController();
  bool _placing = false;

  @override
  void didUpdateWidget(covariant BidActionWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lot.id != widget.lot.id ||
        oldWidget.lot.highestBid != widget.lot.highestBid ||
        oldWidget.lot.minIncrement != widget.lot.minIncrement ||
        oldWidget.lot.startingPrice != widget.lot.startingPrice ||
        oldWidget.lot.endTime != widget.lot.endTime) {
      _syncAmountWithLot();
    }
  }

  @override
  void initState() {
    super.initState();
    _syncAmountWithLot();
  }

  /// Bumps the field up to the new legal minimum when the user had not entered
  /// a higher custom amount.
  void _syncAmountWithLot() {
    final min = widget.lot.minimumNextBid();
    final text = _amountController.text.trim().replaceAll(',', '.');
    final parsed = double.tryParse(text);
    if (parsed == null || parsed < min - 1e-9) {
      _amountController.text = _plainNumber(min);
    }
  }

  String _plainNumber(double v) {
    if (v == v.roundToDouble()) return v.round().toString();
    return v.toString();
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  String _formatMoneyLabel(BuildContext context, double value) {
    final locale = Localizations.localeOf(context).toString();
    final fmt = NumberFormat.currency(
      locale: locale,
      symbol: '',
      decimalDigits: value == value.roundToDouble() ? 0 : 3,
    );
    final suffix = Localizations.localeOf(context).languageCode == 'ar'
        ? ' د.ك'
        : ' KWD';
    return '${fmt.format(value)}$suffix';
  }

  Duration _remaining(AuctionLot lot, DateTime serverNow) {
    return lot.endTime.difference(serverNow);
  }

  /// Safety lock: no bids in the final second (NTP-skewed clock).
  bool _clockAllowsBid(AuctionLot lot, DateTime serverNow) {
    return _remaining(lot, serverNow) > const Duration(seconds: 1);
  }

  /// Registration, permission, deposit, active lot, before official end.
  bool _baseRules({
    required User? user,
    required AuctionParticipant? participant,
    required LotPermission? permission,
    required AuctionDeposit? deposit,
    required AuctionLot lot,
    required DateTime serverNow,
  }) {
    if (user == null) return false;
    if (lot.status != LotStatus.active) return false;
    if (!serverNow.isBefore(lot.endTime)) return false;
    if (participant?.isApproved != true) return false;
    if (permission?.canBid != true || permission?.isActive != true) {
      return false;
    }
    if (deposit?.isPaid != true) return false;
    return true;
  }

  /// Explains why bidding UI is hidden (rules align with [placeAuctionBid]).
  String _ineligibilityMessage(
    AppLocalizations loc, {
    required AuctionLot lot,
    required DateTime serverNow,
    required User? user,
    required AuctionParticipant? participant,
    required LotPermission? permission,
    required AuctionDeposit? deposit,
  }) {
    if (user == null) {
      return loc.auctionBidSignInFirst;
    }
    if (lot.status != LotStatus.active) {
      return loc.auctionBidNotAllowed;
    }
    if (!serverNow.isBefore(lot.endTime)) {
      return loc.auctionBidNotAllowed;
    }
    if (participant == null) {
      return loc.auctionBidRegisterFirst;
    }
    switch (participant.status) {
      case ParticipantStatus.rejected:
        return loc.auctionBidParticipationRejected;
      case ParticipantStatus.blocked:
        return loc.auctionBidNotAllowed;
      case ParticipantStatus.pending:
        return loc.auctionRegPendingReview;
      case ParticipantStatus.approved:
        break;
    }

    if (deposit == null || !deposit.isPaid) {
      return loc.auctionBidCompleteDepositShort;
    }

    if (permission == null ||
        permission.canBid != true ||
        permission.isActive != true) {
      return loc.auctionBidNotAllowed;
    }

    return loc.auctionBidNotAllowed;
  }

  bool _fullyEligible({
    required User? user,
    required AuctionParticipant? participant,
    required LotPermission? permission,
    required AuctionDeposit? deposit,
    required AuctionLot lot,
    required DateTime serverNow,
  }) {
    return _baseRules(
          user: user,
          participant: participant,
          permission: permission,
          deposit: deposit,
          lot: lot,
          serverNow: serverNow,
        ) &&
        _clockAllowsBid(lot, serverNow);
  }

  Future<void> _submit() async {
    if (_placing) return;
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    if (!_clockAllowsBid(widget.lot, widget.serverNow)) {
      _toast(
        context,
        isError: true,
        message: ar ? 'انتهى وقت المزايدة' : 'Bidding time has expired',
      );
      return;
    }

    final raw = _amountController.text.trim().replaceAll(',', '.');
    final amount = double.tryParse(raw);
    if (amount == null || amount <= 0 || !amount.isFinite) {
      _toast(context, isError: true, message: _invalidAmountMessage(context));
      return;
    }

    setState(() => _placing = true);
    try {
      final result = await BidService.placeBid(
        auctionId: widget.auctionId,
        lotId: widget.lotId,
        amount: amount,
        arabicMessages: ar,
      );
      if (!mounted) return;
      if (result.success) {
        HapticFeedback.lightImpact();
        _toast(
          context,
          isError: false,
          message: _successMessage(context, result.antiSnipeExtended == true),
        );
        if (result.lotEndTimeMs != null) {
          // Lot stream will refresh endTime; optional local hint only.
        }
      } else {
        _toast(
          context,
          isError: true,
          message: result.errorMessage ??
              _rejectionMessage(context, result.rejection),
        );
      }
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  String _invalidAmountMessage(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return ar ? 'أدخل مبلغاً صالحاً' : 'Enter a valid amount';
  }

  String _successMessage(BuildContext context, bool extended) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    if (extended) {
      return ar ? 'تم تسجيل مزايدتك (تم تمديد الوقت)' : 'Bid placed (time extended)';
    }
    return ar ? 'تم تسجيل مزايدتك' : 'Bid placed';
  }

  String _rejectionMessage(BuildContext context, BidRejectionReason? r) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    switch (r) {
      case BidRejectionReason.lotNotFound:
        return ar ? 'العنصر غير موجود' : 'Lot not found';
      case BidRejectionReason.lotNotLive:
        return ar ? 'المزايدة غير مفتوحة' : 'Lot is not live';
      case BidRejectionReason.belowMinimum:
        return ar ? 'المبلغ أقل من الحد الأدنى' : 'Below minimum bid';
      case BidRejectionReason.notRegistered:
        return ar ? 'غير مسجّل في المزاد' : 'Not registered';
      case BidRejectionReason.participantNotApproved:
        return ar ? 'التسجيل غير معتمد' : 'Registration not approved';
      case BidRejectionReason.noPermission:
        return ar ? 'لا يوجد إذن للمزايدة' : 'No bidding permission';
      case BidRejectionReason.permissionInactive:
        return ar ? 'إذن المزايدة غير مفعّل' : 'Bidding permission inactive';
      case BidRejectionReason.depositNotPaid:
        return ar ? 'العربون غير مدفوع' : 'Deposit not paid';
      case null:
        return ar ? 'تعذّر تنفيذ المزايدة' : 'Could not place bid';
    }
  }

  void _toast(
    BuildContext context, {
    required bool isError,
    required String message,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade800 : AppColors.navy,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _applyIncrement() {
    final current = double.tryParse(
          _amountController.text.trim().replaceAll(',', '.'),
        ) ??
        widget.lot.minimumNextBid();
    final next = current + widget.lot.minIncrement;
    setState(() {
      _amountController.text = _plainNumber(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context)!;
    final ar = Localizations.localeOf(context).languageCode == 'ar';

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        final user = authSnap.data;
        if (user == null) {
          return _disabledPanel(context, loc.auctionBidSignInFirst);
        }

        return StreamBuilder<AuctionParticipant?>(
          stream: AuctionService.watchParticipant(
            userId: user.uid,
            auctionId: widget.auctionId,
          ),
          builder: (context, partSnap) {
            return StreamBuilder<LotPermission?>(
              stream: PermissionService.watchPermission(
                userId: user.uid,
                lotId: widget.lotId,
              ),
              builder: (context, permSnap) {
                return StreamBuilder<AuctionDeposit?>(
                  stream: DepositService.watchDeposit(
                    userId: user.uid,
                    lotId: widget.lotId,
                  ),
                  builder: (context, depSnap) {
                    if (partSnap.connectionState == ConnectionState.waiting ||
                        permSnap.connectionState == ConnectionState.waiting ||
                        depSnap.connectionState == ConnectionState.waiting) {
                      return _loadingEligibilityPanel(context);
                    }

                    final baseOk = _baseRules(
                      user: user,
                      participant: partSnap.data,
                      permission: permSnap.data,
                      deposit: depSnap.data,
                      lot: widget.lot,
                      serverNow: widget.serverNow,
                    );

                    final canBid = _fullyEligible(
                      user: user,
                      participant: partSnap.data,
                      permission: permSnap.data,
                      deposit: depSnap.data,
                      lot: widget.lot,
                      serverNow: widget.serverNow,
                    );

                    if (!baseOk) {
                      return _disabledPanel(
                        context,
                        _ineligibilityMessage(
                          loc,
                          lot: widget.lot,
                          serverNow: widget.serverNow,
                          user: user,
                          participant: partSnap.data,
                          permission: permSnap.data,
                          deposit: depSnap.data,
                        ),
                      );
                    }

                    if (!canBid) {
                      return _disabledPanel(
                        context,
                        loc.auctionBidLessThanOneSecondLeft,
                      );
                    }

                    final suggested = widget.lot.minimumNextBid();

                    return _EligibleBidShell(
                      statusText: loc.auctionBidInAuctionNow,
                      child: SafeArea(
                        top: false,
                        child: AbsorbPointer(
                          absorbing: _placing,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  ar ? 'مزايدتك' : 'Your bid',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${ar ? 'الحد الأدنى المقترح' : 'Suggested minimum'}: ${_formatMoneyLabel(context, suggested)}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _amountController,
                                        readOnly: _placing,
                                        keyboardType:
                                            const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                        inputFormatters: [
                                          FilteringTextInputFormatter.allow(
                                            RegExp(r'[0-9.,]'),
                                          ),
                                        ],
                                        decoration: InputDecoration(
                                          labelText: ar ? 'المبلغ' : 'Amount',
                                          border: const OutlineInputBorder(),
                                          isDense: true,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Tooltip(
                                      message: ar
                                          ? 'إضافة قيمة الزيادة الدنيا'
                                          : 'Add minimum increment',
                                      child: IconButton.filledTonal(
                                        onPressed:
                                            _placing ? null : _applyIncrement,
                                        icon: const Icon(Icons.add),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  height: 56,
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: _placing ? null : _submit,
                                      borderRadius: BorderRadius.circular(28),
                                      child: Ink(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(28),
                                          gradient: const LinearGradient(
                                            colors: [
                                              AuctionUiColors.amber,
                                              AuctionUiColors.amberDeep,
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: AuctionUiColors.amber
                                                  .withValues(alpha: 0.55),
                                              blurRadius: 20,
                                              spreadRadius: 0,
                                              offset: const Offset(0, 8),
                                            ),
                                            BoxShadow(
                                              color: AuctionUiColors.amberDeep
                                                  .withValues(alpha: 0.28),
                                              blurRadius: 8,
                                              offset: const Offset(0, 3),
                                            ),
                                          ],
                                        ),
                                        child: Center(
                                          child: _placing
                                              ? const SizedBox(
                                                  width: 26,
                                                  height: 26,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2.5,
                                                    color: AppColors.navy,
                                                  ),
                                                )
                                              : Text(
                                                  loc.auctionBidNowButton,
                                                  style: theme.textTheme
                                                      .titleMedium?.copyWith(
                                                    color: AppColors.navy,
                                                    fontWeight: FontWeight.w900,
                                                    letterSpacing: 0.4,
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _loadingEligibilityPanel(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context)!;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  loc.auctionBidCheckingEligibility,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _disabledPanel(BuildContext context, String message) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.lock_outline, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Green chrome + subtle breathing animation when the user may bid.
class _EligibleBidShell extends StatefulWidget {
  const _EligibleBidShell({
    required this.statusText,
    required this.child,
  });

  final String statusText;
  final Widget child;

  @override
  State<_EligibleBidShell> createState() => _EligibleBidShellState();
}

class _EligibleBidShellState extends State<_EligibleBidShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathe;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _breathe,
      builder: (context, child) {
        final t = _breathe.value;
        final topGlow = Color.lerp(
          Colors.green.shade50,
          Colors.green.shade100,
          0.35 + 0.25 * t,
        )!;
        return Material(
          elevation: 10 + 3 * t,
          shadowColor: Colors.green.withValues(alpha: 0.35),
          color: theme.colorScheme.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      topGlow,
                      Colors.green.shade50.withValues(alpha: 0.92),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.green.shade400.withValues(alpha: 0.45 + 0.2 * t),
                      width: 1.2,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.verified_rounded,
                        color: Colors.green.shade800,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.statusText,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: Colors.green.shade900,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              child!,
            ],
          ),
        );
      },
      child: widget.child,
    );
  }
}
