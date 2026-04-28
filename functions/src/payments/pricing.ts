/**
 * Canonical, server-side pricing for paid platform actions.
 *
 * NEVER read the price/amount from a client request. Look it up here and
 * compare the gateway-reported `PaidCurrencyValue` (KWD) against this value.
 *
 * If a price needs to change, update this file AND the matching enforcement
 * branch in `firestore.rules` (e.g. `auctionFee == 100`).
 */

/** Auction listing fee in KWD — single, hard-pinned value. */
export const AUCTION_LISTING_FEE_KWD = 100 as const;

/**
 * Featured-ad pricing — kept in `featurePropertyPaid` because it varies per
 * (durationDays, priceKwd) plan. Re-exported here as a stable lookup table
 * so the webhook + recreate flows can validate amounts without importing
 * the callable module directly.
 */
export interface FeaturePlan {
  durationDays: number;
  priceKwd: number;
}

export const FEATURE_PLANS: readonly FeaturePlan[] = [
  { durationDays: 3, priceKwd: 5 },
  { durationDays: 7, priceKwd: 10 },
  { durationDays: 14, priceKwd: 15 },
  { durationDays: 30, priceKwd: 25 },
] as const;

export function featurePlanFor(
  durationDays: number,
  amountKwd: number
): FeaturePlan | null {
  for (const p of FEATURE_PLANS) {
    if (p.durationDays === durationDays && p.priceKwd === amountKwd) return p;
  }
  return null;
}
