/// Default listing fee for auction property requests (KWD).
/// Server-side [markAuctionFeePaid] validates against stored [auctionFee] on the document.
abstract final class AuctionListingFees {
  AuctionListingFees._();

  static const double defaultKwd = 100;
}
