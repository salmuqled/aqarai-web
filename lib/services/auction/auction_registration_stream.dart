import 'dart:async';

import 'package:aqarai_app/models/auction/auction_deposit.dart';
import 'package:aqarai_app/models/auction/auction_participant.dart';
import 'package:aqarai_app/models/auction/lot_permission.dart';
import 'package:aqarai_app/services/auction/auction_service.dart';
import 'package:aqarai_app/services/auction/deposit_service.dart';
import 'package:aqarai_app/services/auction/permission_service.dart';

/// Single snapshot for [AuctionRegistrationStatusWidget] (one rebuild surface).
class AuctionRegistrationSnapshot {
  const AuctionRegistrationSnapshot({
    required this.ready,
    this.participant,
    this.permission,
    this.deposit,
    this.error,
  });

  final bool ready;
  final AuctionParticipant? participant;
  final LotPermission? permission;
  final AuctionDeposit? deposit;
  final Object? error;
}

/// Merges participant, lot permission, and deposit streams for one user/lot/auction.
Stream<AuctionRegistrationSnapshot> watchAuctionRegistration({
  required String userId,
  required String auctionId,
  required String lotId,
}) {
  AuctionParticipant? participant;
  LotPermission? permission;
  AuctionDeposit? deposit;
  var gotParticipant = false;
  var gotPermission = false;
  var gotDeposit = false;
  Object? error;

  late final StreamController<AuctionRegistrationSnapshot> controller;

  void emit() {
    if (controller.isClosed) return;
    final ready = gotParticipant && gotPermission && gotDeposit;
    controller.add(
      AuctionRegistrationSnapshot(
        ready: ready,
        participant: participant,
        permission: permission,
        deposit: deposit,
        error: error,
      ),
    );
  }

  StreamSubscription<AuctionParticipant?>? subP;
  StreamSubscription<LotPermission?>? subL;
  StreamSubscription<AuctionDeposit?>? subD;

  controller = StreamController<AuctionRegistrationSnapshot>(
    onListen: () {
      subP = AuctionService.watchParticipant(
        userId: userId,
        auctionId: auctionId,
      ).listen(
        (v) {
          participant = v;
          gotParticipant = true;
          emit();
        },
        onError: (Object e, StackTrace _) {
          error = e;
          gotParticipant = true;
          emit();
        },
      );
      subL = PermissionService.watchPermission(
        userId: userId,
        lotId: lotId,
      ).listen(
        (v) {
          permission = v;
          gotPermission = true;
          emit();
        },
        onError: (Object e, StackTrace _) {
          error = e;
          gotPermission = true;
          emit();
        },
      );
      subD = DepositService.watchDeposit(
        userId: userId,
        lotId: lotId,
      ).listen(
        (v) {
          deposit = v;
          gotDeposit = true;
          emit();
        },
        onError: (Object e, StackTrace _) {
          error = e;
          gotDeposit = true;
          emit();
        },
      );
    },
    onCancel: () {
      subP?.cancel();
      subL?.cancel();
      subD?.cancel();
      subP = null;
      subL = null;
      subD = null;
    },
  );

  return controller.stream;
}
