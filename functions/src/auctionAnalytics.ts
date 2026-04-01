/**
 * Auction analytics append-only events → `analytics_events`.
 * All eventType values are lowercase snake_case.
 */
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";

export const ANALYTICS_EVENTS_COLLECTION = "analytics_events";

export const AuctionAnalyticsEventType = {
  BID_PLACED: "bid_placed",
  AUCTION_VIEWED: "auction_viewed",
  USER_OUTBID: "user_outbid",
  AUCTION_WON: "auction_won",
} as const;

export type AuctionAnalyticsEventTypeName =
  (typeof AuctionAnalyticsEventType)[keyof typeof AuctionAnalyticsEventType];

/**
 * Firestore document shape (fixed fields only):
 * - eventType: string
 * - userId: string
 * - lotId: string
 * - timestamp: server timestamp
 */
export async function recordAuctionAnalyticsEvent(
  db: Firestore,
  args: {
    eventType: AuctionAnalyticsEventTypeName | string;
    userId: string;
    lotId: string;
  }
): Promise<void> {
  const userId = args.userId.trim();
  const lotId = args.lotId.trim();
  if (!userId || !lotId) return;

  try {
    await db.collection(ANALYTICS_EVENTS_COLLECTION).add({
      eventType: args.eventType,
      userId,
      lotId,
      timestamp: FieldValue.serverTimestamp(),
    });
  } catch (e) {
    console.error("[auctionAnalytics] write failed", args.eventType, e);
  }
}
