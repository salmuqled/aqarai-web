/**
 * Callable: authoritative auction bid placement (Admin SDK + transaction).
 * - Marks prior `winning` bids as `outbid`
 * - Anti-sniping: extends `lot.endTime` by 30s if &lt; 30s remain
 * - Rate limit: max one bid per user per lot per second (`lot_permissions.lastBidAt`)
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

const LOTS = "lots";
const PARTICIPANTS = "auction_participants";
const PERMISSIONS = "lot_permissions";
const DEPOSITS = "deposits";
const BIDS = "bids";
const LOGS = "auction_logs";

const STATUS_APPROVED = "approved";
const STATUS_PAID = "paid";
const LOT_ACTIVE = "active";
const BID_WINNING = "winning";
const BID_OUTBID = "outbid";

const ANTI_SNIPE_WINDOW_MS = 30_000;
const ANTI_SNIPE_EXTEND_MS = 30_000;
const MIN_BID_INTERVAL_MS = 1_000;

function num(v: unknown): number {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const x = parseFloat(v);
    return Number.isFinite(x) ? x : NaN;
  }
  return NaN;
}

function participantDocId(uid: string, auctionId: string): string {
  return `${uid}_${auctionId}`;
}

function userLotDocId(uid: string, lotId: string): string {
  return `${uid}_${lotId}`;
}

function assertAuthed(request: { auth?: { uid: string } | undefined }): string {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Authentication required");
  }
  return request.auth.uid;
}

function readTimestamp(v: unknown): Timestamp | null {
  if (v instanceof Timestamp) return v;
  if (v && typeof v === "object" && "toMillis" in v) {
    return v as Timestamp;
  }
  return null;
}

export const placeAuctionBid = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = assertAuthed(request);
    const data = request.data as Record<string, unknown> | undefined;
    const auctionId =
      typeof data?.auctionId === "string" ? data.auctionId.trim() : "";
    const lotId = typeof data?.lotId === "string" ? data.lotId.trim() : "";
    const amountRaw = data?.amount;

    if (!auctionId) {
      throw new HttpsError("invalid-argument", "auctionId is required");
    }
    if (!lotId) {
      throw new HttpsError("invalid-argument", "lotId is required");
    }
    const amount = num(amountRaw);
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new HttpsError(
        "invalid-argument",
        "amount must be a positive number"
      );
    }

    const db = admin.firestore();
    const lotRef = db.collection(LOTS).doc(lotId);
    const participantRef = db
      .collection(PARTICIPANTS)
      .doc(participantDocId(uid, auctionId));
    const permissionRef = db
      .collection(PERMISSIONS)
      .doc(userLotDocId(uid, lotId));
    const depositRef = db
      .collection(DEPOSITS)
      .doc(userLotDocId(uid, lotId));

    const winningQuery = db
      .collection(BIDS)
      .where("lotId", "==", lotId)
      .where("status", "==", BID_WINNING);

    const bidRef = db.collection(BIDS).doc();

    const nowMs = Date.now();

    const { newHighest, extendedEnd, newEndTimeMs } = await db.runTransaction(
      async (t) => {
        const lotSnap = await t.get(lotRef);
        const partSnap = await t.get(participantRef);
        const permSnap = await t.get(permissionRef);
        const depSnap = await t.get(depositRef);
        const winningSnap = await t.get(winningQuery);

        if (!lotSnap.exists || !lotSnap.data()) {
          throw new HttpsError("not-found", "Lot not found");
        }
        const lot = lotSnap.data()!;
        if (lot.auctionId !== auctionId) {
          throw new HttpsError(
            "invalid-argument",
            "lotId does not belong to this auction"
          );
        }
        if (lot.status !== LOT_ACTIVE) {
          throw new HttpsError(
            "failed-precondition",
            "Lot is not open for bidding"
          );
        }

        const endTs = readTimestamp(lot.endTime);
        if (!endTs) {
          throw new HttpsError(
            "failed-precondition",
            "Lot endTime is missing"
          );
        }
        const endMs = endTs.toMillis();
        if (nowMs > endMs) {
          throw new HttpsError(
            "failed-precondition",
            "Bidding is closed: current time is after the lot end time"
          );
        }

        if (!permSnap.exists || !permSnap.data()) {
          throw new HttpsError(
            "failed-precondition",
            "No bidding permission for this lot"
          );
        }
        const perm = permSnap.data()!;
        if (perm.userId !== uid || perm.lotId !== lotId) {
          throw new HttpsError(
            "permission-denied",
            "Permission record does not match caller"
          );
        }

        const lastBidAt = readTimestamp(perm.lastBidAt);
        if (lastBidAt && nowMs - lastBidAt.toMillis() < MIN_BID_INTERVAL_MS) {
          throw new HttpsError(
            "resource-exhausted",
            "You can place at most one bid per second on this lot"
          );
        }

        let extendedEnd = false;
        let newEndTimeMs = endMs;
        const remaining = endMs - nowMs;
        if (remaining < ANTI_SNIPE_WINDOW_MS && remaining > 0) {
          newEndTimeMs = endMs + ANTI_SNIPE_EXTEND_MS;
          extendedEnd = true;
        }

        const startingPrice = num(lot.startingPrice);
        const minIncrement = num(lot.minIncrement);
        if (!Number.isFinite(startingPrice) || startingPrice < 0) {
          throw new HttpsError(
            "failed-precondition",
            "Lot startingPrice is invalid"
          );
        }
        if (!Number.isFinite(minIncrement) || minIncrement < 0) {
          throw new HttpsError(
            "failed-precondition",
            "Lot minIncrement is invalid"
          );
        }

        const highestBidRaw = lot.highestBid;
        const hasHighest =
          highestBidRaw !== undefined &&
          highestBidRaw !== null &&
          Number.isFinite(num(highestBidRaw));
        const highestBid = hasHighest ? num(highestBidRaw) : null;

        if (hasHighest && highestBid !== null) {
          if (amount <= highestBid) {
            throw new HttpsError(
              "failed-precondition",
              `Bid must be greater than current highest (${highestBid})`
            );
          }
          const minRequired = highestBid + minIncrement;
          if (amount < minRequired) {
            throw new HttpsError(
              "failed-precondition",
              `Bid must be at least ${minRequired} (highest + min increment)`
            );
          }
        } else {
          if (amount < startingPrice) {
            throw new HttpsError(
              "failed-precondition",
              `Opening bid must be at least ${startingPrice}`
            );
          }
        }

        if (!partSnap.exists || !partSnap.data()) {
          throw new HttpsError(
            "failed-precondition",
            "You are not registered for this auction"
          );
        }
        const part = partSnap.data()!;
        if (part.status !== STATUS_APPROVED) {
          throw new HttpsError(
            "failed-precondition",
            "Auction registration is not approved"
          );
        }
        if (part.userId !== uid || part.auctionId !== auctionId) {
          throw new HttpsError(
            "permission-denied",
            "Participant record does not match caller"
          );
        }

        if (perm.canBid !== true) {
          throw new HttpsError(
            "failed-precondition",
            "Bidding is not allowed for your account on this lot"
          );
        }
        if (perm.isActive !== true) {
          throw new HttpsError(
            "failed-precondition",
            "Live bidding is not active for you on this lot"
          );
        }

        if (!depSnap.exists || !depSnap.data()) {
          throw new HttpsError(
            "failed-precondition",
            "Deposit required before bidding"
          );
        }
        const dep = depSnap.data()!;
        if (dep.userId !== uid || dep.lotId !== lotId) {
          throw new HttpsError(
            "permission-denied",
            "Deposit record does not match caller"
          );
        }
        if (dep.paymentStatus !== STATUS_PAID) {
          throw new HttpsError(
            "failed-precondition",
            "Deposit must be paid before bidding"
          );
        }

        for (const doc of winningSnap.docs) {
          t.update(doc.ref, {
            status: BID_OUTBID,
          });
        }

        const now = FieldValue.serverTimestamp();
        const serverTs = Timestamp.fromMillis(nowMs);

        t.set(bidRef, {
          userId: uid,
          auctionId,
          lotId,
          amount,
          timestamp: now,
          status: BID_WINNING,
          isAutoExtended: extendedEnd,
          createdAt: now,
        });

        const lotUpdate: Record<string, unknown> = {
          highestBid: amount,
          highestBidderId: uid,
          updatedAt: now,
        };
        if (extendedEnd) {
          lotUpdate.endTime = Timestamp.fromMillis(newEndTimeMs);
        }
        t.update(lotRef, lotUpdate);

        t.update(permissionRef, {
          lastBidAt: serverTs,
          updatedAt: now,
        });

        const logRef = db.collection(LOGS).doc();
        t.set(logRef, {
          auctionId,
          lotId,
          action: "bid_placed",
          performedBy: uid,
          details: {
            bidId: bidRef.id,
            amount,
            userId: uid,
            antiSnipeExtended: extendedEnd,
            newEndTimeMs: extendedEnd ? newEndTimeMs : null,
          },
          timestamp: now,
        });

        if (extendedEnd) {
          const extRef = db.collection(LOGS).doc();
          t.set(extRef, {
            auctionId,
            lotId,
            action: "time_extended",
            performedBy: uid,
            details: {
              bidId: bidRef.id,
              previousEndTimeMs: endMs,
              newEndTimeMs,
              extendMs: ANTI_SNIPE_EXTEND_MS,
              reason: "anti_snipe",
            },
            timestamp: now,
          });
        }

        return {
          newHighest: amount,
          extendedEnd,
          newEndTimeMs,
        };
      }
    );

    return {
      success: true,
      highestBid: newHighest,
      bidId: bidRef.id,
      antiSnipeExtended: extendedEnd,
      lotEndTimeMs: extendedEnd ? newEndTimeMs : null,
    };
  }
);
