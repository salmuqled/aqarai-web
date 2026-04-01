/**
 * Shared server-side lot finalization (callable admin + scheduled job).
 * Bids live under `lots/{lotId}/bids/{bidId}` only.
 * Lot end field: `endsAt` (legacy `endTime` supported until migrated).
 */
import { HttpsError } from "firebase-functions/v2/https";
import type {
  DocumentData,
  Firestore,
  QueryDocumentSnapshot,
  Transaction,
} from "firebase-admin/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  AuctionAnalyticsEventType,
  recordAuctionAnalyticsEvent,
} from "./auctionAnalytics";
import { AUCTION_APPROVAL_TIMEOUT_MS } from "./auctionApprovalDeadline";

export const LOTS = "lots";
export const LOGS = "auction_logs";

export const LOT_ACTIVE = "active";
export const LOT_CLOSED = "closed";
export const LOT_SOLD = "sold";
/** Lot had winning bid(s) at end; awaiting seller + admin before `sold`. */
export const LOT_PENDING_ADMIN_REVIEW = "pending_admin_review";
export const LOT_REJECTED = "rejected";
export const BID_WINNING = "winning";
export const BID_WON = "won";
export const BID_OUTBID = "outbid";

export function num(v: unknown): number {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const x = parseFloat(v);
    return Number.isFinite(x) ? x : NaN;
  }
  return NaN;
}

export function readTimestamp(v: unknown): Timestamp | null {
  if (v instanceof Timestamp) return v;
  if (v && typeof v === "object" && "toMillis" in v) {
    return v as Timestamp;
  }
  return null;
}

function readLotEndsAt(lot: DocumentData): Timestamp | null {
  return readTimestamp(lot.endsAt) ?? readTimestamp(lot.endTime);
}

export type FinalizeActorKind = "admin" | "system";

export type FinalizeLotCoreResult = {
  alreadyFinalized: boolean;
  lotId: string;
  auctionId: string;
  lotStatus: string;
  winnerUserId: string | null;
  finalPrice: number | null;
  winningBidId: string | null;
};

function buildAlreadyFinalized(
  lotId: string,
  lot: DocumentData
): FinalizeLotCoreResult {
  const status = String(lot.status ?? "");
  let winnerUserId: string | null = null;
  const wu = lot.winnerUserId;
  const wid = lot.winnerId;
  if (wu != null && String(wu).trim() !== "") {
    winnerUserId = String(wu);
  } else if (wid != null && String(wid).trim() !== "") {
    winnerUserId = String(wid);
  } else {
    const hbid = lot.currentHighBidderId ?? lot.highestBidderId;
    if (hbid != null && String(hbid).trim() !== "") {
      winnerUserId = String(hbid);
    }
  }
  const fp = num(lot.finalPrice);
  const hb = num(lot.currentHighBid ?? lot.highestBid);
  const finalPrice =
    Number.isFinite(fp) && fp > 0
      ? fp
      : Number.isFinite(hb) && hb > 0
        ? hb
        : null;
  const wbid = lot.winningBidId;
  const winningBidId =
    typeof wbid === "string" && wbid.trim() ? wbid.trim() : null;
  return {
    alreadyFinalized: true,
    lotId,
    auctionId: String(lot.auctionId ?? ""),
    lotStatus: status,
    winnerUserId,
    finalPrice,
    winningBidId,
  };
}

/**
 * Pick exactly one winning bid when multiple docs still have status `winning`
 * (should be rare). Higher amount wins; tie → latest createdAt; tie → doc id.
 */
export function pickSingleTopWinningBid(
  docs: QueryDocumentSnapshot<DocumentData>[]
): QueryDocumentSnapshot<DocumentData> {
  let top = docs[0]!;
  for (let i = 1; i < docs.length; i++) {
    const d = docs[i]!;
    if (compareWinningBids(d, top) > 0) top = d;
  }
  return top;
}

function compareWinningBids(
  a: QueryDocumentSnapshot<DocumentData>,
  b: QueryDocumentSnapshot<DocumentData>
): number {
  const amtA = num(a.data().amount);
  const amtB = num(b.data().amount);
  if (amtA !== amtB) return amtA > amtB ? 1 : -1;
  const ta = readTimestamp(a.data().createdAt)?.toMillis() ?? 0;
  const tb = readTimestamp(b.data().createdAt)?.toMillis() ?? 0;
  if (ta !== tb) return ta > tb ? 1 : -1;
  return a.id.localeCompare(b.id);
}

/**
 * Runs finalization in a single Firestore transaction (idempotent).
 */
export async function runFinalizeLotTransaction(
  db: Firestore,
  options: {
    lotId: string;
    performedBy: string;
    nowMs: number;
    actorKind: FinalizeActorKind;
    enforceEndTimePassed: boolean;
  }
): Promise<FinalizeLotCoreResult> {
  const {
    lotId,
    performedBy,
    nowMs,
    actorKind,
    enforceEndTimePassed,
  } = options;

  const lotRef = db.collection(LOTS).doc(lotId);
  const winningQuery = lotRef.collection("bids").where("status", "==", BID_WINNING);

  const result = await db.runTransaction(async (t: Transaction) => {
    const lotSnap = await t.get(lotRef);
    if (!lotSnap.exists || !lotSnap.data()) {
      throw new HttpsError("not-found", "Lot not found");
    }
    const lot = lotSnap.data()!;
    const auctionId = String(lot.auctionId ?? "");

    const status = String(lot.status ?? "");
    if (
      status === LOT_CLOSED ||
      status === LOT_SOLD ||
      status === LOT_PENDING_ADMIN_REVIEW ||
      status === LOT_REJECTED
    ) {
      return buildAlreadyFinalized(lotId, lot);
    }

    if (status !== LOT_ACTIVE) {
      throw new HttpsError(
        "failed-precondition",
        `Lot cannot be finalized from status: ${status}`
      );
    }

    const endTs = readLotEndsAt(lot);
    if (!endTs) {
      throw new HttpsError("failed-precondition", "Lot endsAt is missing");
    }
    // Finalize only when current time is at or after endsAt (same boundary as placeAuctionBid rejection).
    if (enforceEndTimePassed && endTs.toMillis() > nowMs) {
      throw new HttpsError(
        "failed-precondition",
        "Lot end time has not passed yet"
      );
    }

    const winningSnap = await t.get(winningQuery);
    const now = FieldValue.serverTimestamp();

    let winnerUserId: string | null = null;
    let highestBid: number | null = null;
    let winningBidId: string | null = null;
    let lotStatus: string;

    if (winningSnap.empty) {
      lotStatus = LOT_CLOSED;
      t.update(lotRef, {
        status: LOT_CLOSED,
        winnerId: null,
        winnerUserId: null,
        winningBidId: null,
        finalPrice: null,
        currentHighBid: null,
        currentHighBidderId: null,
        finalizedAt: now,
        sellerApprovalStatus: FieldValue.delete(),
        adminApproved: FieldValue.delete(),
        sellerApprovalAt: FieldValue.delete(),
        adminDecisionAt: FieldValue.delete(),
        approvalDeadlineAt: FieldValue.delete(),
        rejectionReason: FieldValue.delete(),
        approvalOneHourWarningSent: FieldValue.delete(),
        approvalTenMinWarningSent: FieldValue.delete(),
        approvalOneMinWarningSent: FieldValue.delete(),
        updatedAt: now,
      });
    } else {
      lotStatus = LOT_PENDING_ADMIN_REVIEW;
      const approvalDeadlineAt = Timestamp.fromMillis(
        nowMs + AUCTION_APPROVAL_TIMEOUT_MS
      );
      t.update(lotRef, {
        status: LOT_PENDING_ADMIN_REVIEW,
        sellerApprovalStatus: "pending",
        adminApproved: false,
        sellerApprovalAt: FieldValue.delete(),
        adminDecisionAt: FieldValue.delete(),
        approvalDeadlineAt,
        winnerId: null,
        winnerUserId: null,
        winningBidId: null,
        finalPrice: null,
        finalizedAt: FieldValue.delete(),
        rejectionReason: FieldValue.delete(),
        approvalOneHourWarningSent: FieldValue.delete(),
        approvalTenMinWarningSent: FieldValue.delete(),
        approvalOneMinWarningSent: FieldValue.delete(),
        updatedAt: now,
      });
    }

    const logRef = db.collection(LOGS).doc();
    t.set(logRef, {
      auctionId: auctionId || null,
      lotId,
      action:
        lotStatus === LOT_PENDING_ADMIN_REVIEW
          ? "lot_pending_admin_review"
          : "lot_closed",
      performedBy,
      details: {
        winnerUserId,
        winnerId: winnerUserId,
        finalPrice: highestBid,
        currentHighBid: highestBid,
        winningBidId,
        hadWinningBid: !winningSnap.empty,
        lotStatus,
        actorKind,
        approvalDeadlineAtMillis:
          lotStatus === LOT_PENDING_ADMIN_REVIEW
            ? nowMs + AUCTION_APPROVAL_TIMEOUT_MS
            : null,
      },
      timestamp: now,
    });

    return {
      alreadyFinalized: false,
      lotId,
      auctionId,
      lotStatus,
      winnerUserId,
      finalPrice: highestBid,
      winningBidId,
    };
  });

  if (
    !result.alreadyFinalized &&
    result.lotStatus === LOT_SOLD &&
    result.winnerUserId &&
    result.winnerUserId.trim() !== ""
  ) {
    void recordAuctionAnalyticsEvent(db, {
      eventType: AuctionAnalyticsEventType.AUCTION_WON,
      userId: result.winnerUserId,
      lotId: result.lotId,
    });
  }

  return result;
}
