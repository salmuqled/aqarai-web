/// Firestore: `analytics_events/{autoId}`
///
/// **Schema**
/// | Field | Type | Notes |
/// |-------|------|--------|
/// | `eventType` | string | `bid_placed` \| `auction_viewed` \| `user_outbid` \| `auction_won` |
/// | `userId` | string | Actor (bidder, viewer, outbid user, or winner) |
/// | `lotId` | string | `lots/{lotId}` document id |
/// | `timestamp` | timestamp | Server time (`FieldValue.serverTimestamp()` or Admin SDK) |
///
/// **Writers**
/// - `auction_viewed`: Flutter (signed-in users), rules-restricted.
/// - `bid_placed`, `user_outbid`, `auction_won`: Cloud Functions (Admin SDK).
abstract final class AuctionAnalytics {
  AuctionAnalytics._();

  static const String collection = 'analytics_events';

  static const String bidPlaced = 'bid_placed';
  static const String auctionViewed = 'auction_viewed';
  static const String userOutbid = 'user_outbid';
  static const String auctionWon = 'auction_won';
}
