/// Lifecycle of an auction event (MoC-aligned).
enum AuctionStatus {
  draft('draft'),
  /// Pre-registration visibility (catalog / discovery).
  upcoming('upcoming'),
  registrationOpen('registration_open'),
  closed('closed'),
  live('live'),
  finished('finished');

  const AuctionStatus(this.firestoreValue);
  final String firestoreValue;

  static AuctionStatus fromFirestore(String? raw) {
    final v = raw?.trim() ?? '';
    for (final e in AuctionStatus.values) {
      if (e.firestoreValue == v) return e;
    }
    return AuctionStatus.draft;
  }
}

/// Single property / unit within an auction.
enum LotStatus {
  pending('pending'),
  active('active'),
  closed('closed'),
  sold('sold'),
  /// Auction time ended with bids; awaiting seller + admin before winner is locked.
  pendingAdminReview('pending_admin_review'),
  rejected('rejected'),
  ended('ended');

  const LotStatus(this.firestoreValue);
  final String firestoreValue;

  static LotStatus fromFirestore(String? raw) {
    final v = raw?.trim() ?? '';
    for (final e in LotStatus.values) {
      if (e.firestoreValue == v) return e;
    }
    return LotStatus.pending;
  }
}

/// Values for `lots.rejectionReason` when [LotStatus.rejected].
abstract final class LotRejectionReason {
  LotRejectionReason._();

  static const approvalTimeout = 'approval_timeout';
  static const adminRejected = 'admin_rejected';
  static const sellerRejected = 'seller_rejected';
}

/// Seller response for a lot in [LotStatus.pendingAdminReview].
enum LotSellerApprovalStatus {
  pending('pending'),
  approved('approved'),
  rejected('rejected');

  const LotSellerApprovalStatus(this.firestoreValue);
  final String firestoreValue;

  static LotSellerApprovalStatus? fromFirestore(String? raw) {
    final v = raw?.trim() ?? '';
    if (v.isEmpty) return null;
    for (final e in LotSellerApprovalStatus.values) {
      if (e.firestoreValue == v) return e;
    }
    return null;
  }
}

enum ParticipantStatus {
  pending('pending'),
  approved('approved'),
  rejected('rejected'),
  blocked('blocked');

  const ParticipantStatus(this.firestoreValue);
  final String firestoreValue;

  static ParticipantStatus fromFirestore(String? raw) {
    final v = raw?.trim() ?? '';
    for (final e in ParticipantStatus.values) {
      if (e.firestoreValue == v) return e;
    }
    return ParticipantStatus.pending;
  }
}

enum DepositType {
  fixed('fixed'),
  percentage('percentage');

  const DepositType(this.firestoreValue);
  final String firestoreValue;

  static DepositType fromFirestore(String? raw) {
    final v = raw?.trim() ?? '';
    for (final e in DepositType.values) {
      if (e.firestoreValue == v) return e;
    }
    return DepositType.fixed;
  }
}

enum DepositPaymentStatus {
  pending('pending'),
  paid('paid'),
  failed('failed'),
  refunded('refunded'),
  forfeited('forfeited');

  const DepositPaymentStatus(this.firestoreValue);
  final String firestoreValue;

  static DepositPaymentStatus fromFirestore(String? raw) {
    final v = raw?.trim() ?? '';
    for (final e in DepositPaymentStatus.values) {
      if (e.firestoreValue == v) return e;
    }
    return DepositPaymentStatus.pending;
  }
}

enum BidStatus {
  valid('valid'),
  rejected('rejected'),
  winning('winning'),
  outbid('outbid'),
  won('won');

  const BidStatus(this.firestoreValue);
  final String firestoreValue;

  static BidStatus fromFirestore(String? raw) {
    final v = raw?.trim() ?? '';
    for (final e in BidStatus.values) {
      if (e.firestoreValue == v) return e;
    }
    return BidStatus.valid;
  }
}

/// Known values for [AuctionLogEntry.action] (extend as needed).
abstract final class AuctionLogActions {
  AuctionLogActions._();

  static const String bidPlaced = 'bid_placed';
  static const String timeExtended = 'time_extended';
  static const String lotStarted = 'lot_started';
  static const String lotClosed = 'lot_closed';
  static const String lotSold = 'lot_sold';
  static const String userBlocked = 'user_blocked';
  static const String participantApproved = 'participant_approved';
  static const String participantRejected = 'participant_rejected';
  static const String depositPaid = 'deposit_paid';
  static const String depositRefunded = 'deposit_refunded';
  static const String permissionGranted = 'permission_granted';
  static const String permissionRevoked = 'permission_revoked';
  static const String auctionStatusChanged = 'auction_status_changed';
  static const String lotsSuperseded = 'lots_superseded';
  static const String biddingPaused = 'bidding_paused';
  static const String biddingResumed = 'bidding_resumed';
}

/// Admin workflow for [AuctionFirestorePaths.auctionRequests].
enum AuctionRequestStatus {
  pending('pending'),
  approved('approved'),
  rejected('rejected');

  const AuctionRequestStatus(this.firestoreValue);
  final String firestoreValue;

  static AuctionRequestStatus fromFirestore(String? raw) {
    final v = raw?.trim() ?? '';
    for (final e in AuctionRequestStatus.values) {
      if (e.firestoreValue == v) return e;
    }
    return AuctionRequestStatus.pending;
  }
}
