/// Canonical listing fee for auction property requests (KWD).
///
/// Hard-pinned at 100 KWD as part of Financial Hardening Phase 1. The same
/// constant is enforced server-side (`AUCTION_LISTING_FEE_KWD` in
/// `functions/src/payments/pricing.ts`) AND in `firestore.rules`
/// (`auctionFee == 100` on `auction_requests` create). All three must move
/// together if the fee ever changes.
abstract final class AuctionListingFees {
  AuctionListingFees._();

  static const double defaultKwd = 100;
}
