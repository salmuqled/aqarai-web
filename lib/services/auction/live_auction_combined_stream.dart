import 'dart:async';

import 'package:aqarai_app/models/auction/auction_bid.dart';
import 'package:aqarai_app/models/auction/auction_lot.dart';
import 'package:aqarai_app/services/auction/bid_service.dart';
import 'package:aqarai_app/services/auction/lot_service.dart';

/// Single emission surface for lot + bids so the UI uses one listener (fewer
/// duplicate rebuilds than nested [StreamBuilder]s).
class LiveAuctionCombinedState {
  const LiveAuctionCombinedState({
    required this.lot,
    required this.bids,
    this.lotError,
    this.bidsError,
    required this.lotReady,
    required this.bidsReady,
  });

  final AuctionLot? lot;
  final List<AuctionBid> bids;
  final Object? lotError;
  final Object? bidsError;
  final bool lotReady;
  final bool bidsReady;

  bool get hasLotError => lotError != null;
  bool get hasBidsError => bidsError != null;
}

/// Merges [LotService.watchLot] and [BidService.watchBidsForLot] into one stream.
Stream<LiveAuctionCombinedState> watchLiveAuctionCombined(
  String lotId, {
  int bidLimit = 20,
}) {
  AuctionLot? lot;
  List<AuctionBid> bids = [];
  Object? lotError;
  Object? bidsError;
  var lotEmitted = false;
  var bidsEmitted = false;

  StreamSubscription<AuctionLot?>? subLot;
  StreamSubscription<List<AuctionBid>>? subBids;

  late final StreamController<LiveAuctionCombinedState> controller;

  void emit() {
    if (!controller.isClosed) {
      controller.add(
        LiveAuctionCombinedState(
          lot: lot,
          bids: List<AuctionBid>.unmodifiable(bids),
          lotError: lotError,
          bidsError: bidsError,
          lotReady: lotEmitted || lotError != null,
          bidsReady: bidsEmitted || bidsError != null,
        ),
      );
    }
  }

  controller = StreamController<LiveAuctionCombinedState>(
    onListen: () {
      subLot = LotService.watchLot(lotId).listen(
        (l) {
          lot = l;
          lotError = null;
          lotEmitted = true;
          emit();
        },
        onError: (Object e, StackTrace st) {
          lotError = e;
          lotEmitted = true;
          emit();
        },
      );

      subBids = BidService.watchBidsForLot(lotId, limit: bidLimit).listen(
        (list) {
          bids = list;
          bidsError = null;
          bidsEmitted = true;
          emit();
        },
        onError: (Object e, StackTrace st) {
          bidsError = e;
          bidsEmitted = true;
          emit();
        },
      );
    },
    onCancel: () {
      subLot?.cancel();
      subBids?.cancel();
      subLot = null;
      subBids = null;
    },
  );

  return controller.stream;
}
