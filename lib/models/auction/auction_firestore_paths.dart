/// Firestore collection names for the auction subsystem.
abstract final class AuctionFirestorePaths {
  AuctionFirestorePaths._();

  static const String auctions = 'auctions';
  static const String lots = 'lots';
  /// Safe mirror of [lots] for public catalog UIs (Cloud Function–synced).
  static const String publicLots = 'public_lots';
  static const String participants = 'auction_participants';
  static const String lotPermissions = 'lot_permissions';
  static const String deposits = 'deposits';
  static const String bids = 'bids';
  static const String logs = 'auction_logs';
  /// User-submitted requests to list a property in an auction (admin review).
  static const String auctionRequests = 'auction_requests';
}
