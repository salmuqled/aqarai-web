/// During a one-time Firestore migration from legacy lot field names
/// (`endTime`, `highestBid`, `highestBidderId`) to canonical names
/// (`endsAt`, `currentHighBid`, `currentHighBidderId`), set this to `true`
/// so clients read canonical first and fall back to legacy.
///
/// **After migration completes everywhere, set to `false` and remove
/// legacy branches from [AuctionLot.fromFirestore].**
const bool kAuctionReadLegacyLotFields = false;
