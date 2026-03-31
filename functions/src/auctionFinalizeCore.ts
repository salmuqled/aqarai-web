/**
 * Shared server-side lot finalization (callable admin + scheduled job).
 * Idempotent: lots already `sold` or `closed` return without duplicate writes.
 */
import { HttpsError } from "firebase-functions/v2/https";
import type { DocumentData, Firestore, Transaction } from "firebase-admin/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

export const LOTS = "lots";
export const BIDS = "bids";
export const LOGS = "auction_logs";

export const LOT_ACTIVE = "active";
export const LOT_CLOSED = "closed";
export const LOT_SOLD = "sold";
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
  const wid = lot.winnerId;
  if (wid != null && String(wid).trim() !== "") {
    winnerUserId = String(wid);
  } else {
    const hbid = lot.highestBidderId;
    if (hbid != null && String(hbid).trim() !== "") {
      winnerUserId = String(hbid);
    }
  }
  const fp = num(lot.finalPrice);
  const hb = num(lot.highestBid);
  const finalPrice =
    Number.isFinite(fp) && fp > 0
      ? fp
      : Number.isFinite(hb) && hb > 0
        ? hb
        : null;
  return {
    alreadyFinalized: true,
    lotId,
    auctionId: String(lot.auctionId ?? ""),
    lotStatus: status,
    winnerUserId,
    finalPrice,
    winningBidId: null,
  };
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
    /** When false, skips endTime check (not used; callers always enforce). */
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
  const winningQuery = db
    .collection(BIDS)
    .where("lotId", "==", lotId)
    .where("status", "==", BID_WINNING);

  return db.runTransaction(async (t: Transaction) => {
    const lotSnap = await t.get(lotRef);
    if (!lotSnap.exists || !lotSnap.data()) {
      throw new HttpsError("not-found", "Lot not found");
    }
    const lot = lotSnap.data()!;
    const auctionId = String(lot.auctionId ?? "");

    const status = String(lot.status ?? "");
    if (status === LOT_CLOSED || status === LOT_SOLD) {
      return buildAlreadyFinalized(lotId, lot);
    }

    if (status !== LOT_ACTIVE) {
      throw new HttpsError(
        "failed-precondition",
        `Lot cannot be finalized from status: ${status}`
      );
    }

    const endTs = readTimestamp(lot.endTime);
    if (!endTs) {
      throw new HttpsError("failed-precondition", "Lot endTime is missing");
    }
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
        finalPrice: null,
        finalizedAt: now,
        updatedAt: now,
      });
    } else {
      lotStatus = LOT_SOLD;
      let topDoc = winningSnap.docs[0];
      let topAmount = num(topDoc.data().amount);
      for (let i = 1; i < winningSnap.docs.length; i++) {
        const d = winningSnap.docs[i];
        const a = num(d.data().amount);
        if (a > topAmount) {
          topAmount = a;
          topDoc = d;
        }
      }

      for (const d of winningSnap.docs) {
        if (d.id === topDoc.id) {
          t.update(d.ref, { status: BID_WON });
        } else {
          t.update(d.ref, { status: BID_OUTBID });
        }
      }

      const topData = topDoc.data();
      winnerUserId = String(topData.userId ?? "");
      highestBid = num(topData.amount);
      winningBidId = topDoc.id;

      t.update(lotRef, {
        status: LOT_SOLD,
        winnerId: winnerUserId,
        finalPrice: highestBid,
        highestBid: highestBid,
        highestBidderId: winnerUserId,
        finalizedAt: now,
        updatedAt: now,
      });
    }

    const logRef = db.collection(LOGS).doc();
    t.set(logRef, {
      auctionId: auctionId || null,
      lotId,
      action: "lot_closed",
      performedBy,
      details: {
        winnerUserId,
        winnerId: winnerUserId,
        finalPrice: highestBid,
        highestBid,
        winningBidId,
        hadWinningBid: !winningSnap.empty,
        lotStatus,
        actorKind,
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
}
