/**
 * When seller + admin have both approved a `pending_admin_review` lot, complete the sale
 * (status sold, bids won/outbid, audit log). Used inside Firestore transactions.
 */
import { HttpsError } from "firebase-functions/v2/https";
import type {
  DocumentData,
  Firestore,
  QueryDocumentSnapshot,
  Transaction,
} from "firebase-admin/firestore";
import { FieldValue } from "firebase-admin/firestore";

import {
  AuctionAnalyticsEventType,
  recordAuctionAnalyticsEvent,
} from "./auctionAnalytics";
import {
  BID_OUTBID,
  BID_WON,
  LOGS,
  LOT_PENDING_ADMIN_REVIEW,
  LOT_SOLD,
  num,
  pickSingleTopWinningBid,
} from "./auctionFinalizeCore";

export function readCurrentHighBidderId(lot: DocumentData): string | null {
  const a = lot.currentHighBidderId;
  const b = lot.highestBidderId;
  const s =
    typeof a === "string" && a.trim()
      ? a.trim()
      : typeof b === "string" && b.trim()
        ? b.trim()
        : "";
  return s || null;
}

export function readCurrentHighBidAmount(lot: DocumentData): number | null {
  const a = lot.currentHighBid;
  const b = lot.highestBid;
  const v = a !== undefined && a !== null ? a : b;
  if (v === undefined || v === null) return null;
  const n = num(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

export type SaleCompletionResult = {
  sold: boolean;
  winnerUserId?: string;
};

/**
 * If effective lot state has both approvals, writes sold state + bid outcomes + log.
 * Call only after reading [winningSnap] in the same transaction (all reads before writes).
 */
export function tryApplySaleCompletionInTransaction(
  t: Transaction,
  db: Firestore,
  lotRef: FirebaseFirestore.DocumentReference<DocumentData>,
  lotId: string,
  /** Lot fields merged with in-txn updates (e.g. adminApproved / sellerApprovalStatus). */
  lotEffective: DocumentData,
  auctionId: string,
  winningSnap: FirebaseFirestore.QuerySnapshot<DocumentData>,
  performedBy: string
): SaleCompletionResult {
  if (String(lotEffective.status ?? "") !== LOT_PENDING_ADMIN_REVIEW) {
    return { sold: false };
  }
  if (String(lotEffective.sellerApprovalStatus ?? "") !== "approved") {
    return { sold: false };
  }
  if (lotEffective.adminApproved !== true) {
    return { sold: false };
  }

  const winnerUserId = readCurrentHighBidderId(lotEffective);
  const highAmount = readCurrentHighBidAmount(lotEffective);
  if (!winnerUserId || highAmount === null) {
    throw new HttpsError(
      "failed-precondition",
      "Cannot complete sale: missing high bidder or amount on lot"
    );
  }

  if (winningSnap.empty) {
    throw new HttpsError(
      "failed-precondition",
      "Cannot complete sale: no winning bids on lot"
    );
  }

  const now = FieldValue.serverTimestamp();
  const topDoc = pickSingleTopWinningBid(
    winningSnap.docs as QueryDocumentSnapshot<DocumentData>[]
  );

  for (const d of winningSnap.docs) {
    if (d.id === topDoc.id) {
      t.update(d.ref, { status: BID_WON });
    } else {
      t.update(d.ref, { status: BID_OUTBID });
    }
  }

  const topData = topDoc.data();
  const topAmount = num(topData.amount);
  const finalAmt =
    Number.isFinite(topAmount) && topAmount > 0 ? topAmount : highAmount;
  const winningBidId = topDoc.id;
  const wUid = String(topData.userId ?? "").trim() || winnerUserId;

  t.update(lotRef, {
    status: LOT_SOLD,
    winnerId: wUid,
    winnerUserId: wUid,
    winningBidId,
    finalPrice: finalAmt,
    currentHighBid: finalAmt,
    currentHighBidderId: wUid,
    finalizedAt: now,
    approvalDeadlineAt: FieldValue.delete(),
    rejectionReason: FieldValue.delete(),
    approvalOneHourWarningSent: FieldValue.delete(),
    approvalTenMinWarningSent: FieldValue.delete(),
    approvalOneMinWarningSent: FieldValue.delete(),
    updatedAt: now,
  });

  const logRef = db.collection(LOGS).doc();
  t.set(logRef, {
    auctionId: auctionId || null,
    lotId,
    action: "lot_sold_after_approvals",
    performedBy,
    details: {
      winnerUserId: wUid,
      winningBidId,
      finalPrice: finalAmt,
    },
    timestamp: now,
  });

  return { sold: true, winnerUserId: wUid };
}

export function recordAuctionWonAfterSale(
  db: Firestore,
  winnerUserId: string,
  lotId: string
): void {
  void recordAuctionAnalyticsEvent(db, {
    eventType: AuctionAnalyticsEventType.AUCTION_WON,
    userId: winnerUserId,
    lotId,
  });
}
