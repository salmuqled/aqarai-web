/**
 * Callable: authoritative auction bid placement (Admin SDK + transaction).
 * - Writes bids ONLY under `lots/{lotId}/bids/{bidId}` (canonical).
 * - Bid document ID = `clientRequestId` (UUID) so duplicates are impossible per lot.
 * - Bid docs: `createdAt: serverTimestamp()`, `clientRequestId` field stored on the bid.
 * - Idempotent replay: same user + same amount + same clientRequestId → success, no double write.
 * - Rate limits (per user per lot): min interval between bids + max bids per rolling minute window.
 * - Lot fields: `currentHighBid`, `currentHighBidderId`, `endsAt`, `bidCount`.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  AuctionAnalyticsEventType,
  recordAuctionAnalyticsEvent,
} from "./auctionAnalytics";
import { sendAuctionOutbidNotification } from "./auctionOutbidNotification";

const LOTS = "lots";
const PARTICIPANTS = "auction_participants";
const PERMISSIONS = "lot_permissions";
const DEPOSITS = "deposits";
const LOGS = "auction_logs";

const STATUS_APPROVED = "approved";
const STATUS_PAID = "paid";
const LOT_ACTIVE = "active";
const BID_WINNING = "winning";
const BID_OUTBID = "outbid";

const ANTI_SNIPE_WINDOW_MS = 30_000;
const ANTI_SNIPE_EXTEND_MS = 30_000;

/** Minimum time between *new* bids (same user, same lot). */
const MIN_BID_INTERVAL_MS = 2_500;

/** Rolling window for burst cap (permission doc). */
const BID_RATE_WINDOW_MS = 60_000;
const MAX_BIDS_PER_RATE_WINDOW = 20;

/** RFC 4122 UUID v4 (lowercase hex + hyphens). */
const UUID_V4_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

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

/** Canonical lot end; supports legacy `endTime` until DB migrated. */
function readLotEndsAt(lot: Record<string, unknown>): Timestamp | null {
  return readTimestamp(lot.endsAt) ?? readTimestamp(lot.endTime);
}

function readCurrentHighBid(lot: Record<string, unknown>): number | null {
  const a = lot.currentHighBid;
  const b = lot.highestBid;
  const v = a !== undefined && a !== null ? a : b;
  if (v === undefined || v === null) return null;
  const n = num(v);
  return Number.isFinite(n) ? n : null;
}

/** Previous leading bidder on the lot (canonical or legacy field). */
function readPreviousHighBidderId(lot: Record<string, unknown>): string | null {
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

function assertValidClientRequestId(raw: unknown): string {
  if (typeof raw !== "string") {
    throw new HttpsError(
      "invalid-argument",
      "clientRequestId is required and must be a string (UUID v4)"
    );
  }
  const id = raw.trim().toLowerCase();
  if (id.length > 128 || !UUID_V4_REGEX.test(id)) {
    throw new HttpsError(
      "invalid-argument",
      "clientRequestId must be a valid UUID v4"
    );
  }
  return id;
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
    const clientRequestId = assertValidClientRequestId(data?.clientRequestId);

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
    const bidRef = lotRef.collection("bids").doc(clientRequestId);
    const participantRef = db
      .collection(PARTICIPANTS)
      .doc(participantDocId(uid, auctionId));
    const permissionRef = db
      .collection(PERMISSIONS)
      .doc(userLotDocId(uid, lotId));
    const depositRef = db
      .collection(DEPOSITS)
      .doc(userLotDocId(uid, lotId));

    const winningQuery = lotRef.collection("bids").where("status", "==", BID_WINNING);

    const nowMs = Date.now();

    const {
      newHighest,
      extendedEnd,
      newEndTimeMs,
      idempotent,
      outbidNotifyUid,
    } = await db.runTransaction(async (t) => {
        const lotSnap = await t.get(lotRef);
        const existingBidSnap = await t.get(bidRef);
        const partSnap = await t.get(participantRef);
        const permSnap = await t.get(permissionRef);
        const depSnap = await t.get(depositRef);
        const winningSnap = await t.get(winningQuery);

        if (!lotSnap.exists || !lotSnap.data()) {
          throw new HttpsError("not-found", "Lot not found");
        }
        const lot = lotSnap.data()!;

        if (existingBidSnap.exists && existingBidSnap.data()) {
          const eb = existingBidSnap.data()!;
          if (eb.userId !== uid) {
            throw new HttpsError(
              "permission-denied",
              "This clientRequestId is already associated with another bid"
            );
          }
          if (Math.abs(num(eb.amount) - amount) > 1e-9) {
            throw new HttpsError(
              "failed-precondition",
              "clientRequestId was already used with a different amount"
            );
          }
          const endTs = readLotEndsAt(lot);
          const high = readCurrentHighBid(lot) ?? amount;
          return {
            newHighest: high,
            extendedEnd: false,
            newEndTimeMs: endTs ? endTs.toMillis() : nowMs,
            idempotent: true,
            outbidNotifyUid: null as string | null,
          };
        }

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

        const endTs = readLotEndsAt(lot);
        if (!endTs) {
          throw new HttpsError("failed-precondition", "Lot endsAt is missing");
        }
        const endMs = endTs.toMillis();
        // Reject at endsAt instant and after (aligns with finalize eligibility).
        if (nowMs >= endMs) {
          throw new HttpsError(
            "failed-precondition",
            "Bidding is closed: current time is after the lot end time"
          );
        }

        if (readTimestamp(lot.finalizedAt)) {
          throw new HttpsError(
            "failed-precondition",
            "Lot is already finalized; bidding is closed"
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
            `Wait at least ${MIN_BID_INTERVAL_MS / 1000} seconds between bids on this lot`
          );
        }

        let windowStart =
          typeof perm.bidRateWindowStartMs === "number"
            ? perm.bidRateWindowStartMs
            : 0;
        let windowCount =
          typeof perm.bidRateWindowCount === "number"
            ? perm.bidRateWindowCount
            : 0;
        if (windowStart === 0 || nowMs - windowStart > BID_RATE_WINDOW_MS) {
          windowStart = nowMs;
          windowCount = 0;
        }
        if (windowCount >= MAX_BIDS_PER_RATE_WINDOW) {
          throw new HttpsError(
            "resource-exhausted",
            `Too many bids in the last ${BID_RATE_WINDOW_MS / 1000} seconds on this lot`
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

        const highestBid = readCurrentHighBid(lot);
        const hasHighest = highestBid !== null && highestBid > 0;

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

        const previousHighBidderId = readPreviousHighBidderId(lot);
        const shouldNotifyOutbid =
          hasHighest &&
          previousHighBidderId !== null &&
          previousHighBidderId !== uid;

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
          status: BID_WINNING,
          isAutoExtended: extendedEnd,
          createdAt: now,
          clientRequestId,
        });

        const lotUpdate: Record<string, unknown> = {
          currentHighBid: amount,
          currentHighBidderId: uid,
          bidCount: FieldValue.increment(1),
          updatedAt: now,
        };
        if (extendedEnd) {
          lotUpdate.endsAt = Timestamp.fromMillis(newEndTimeMs);
        }
        t.update(lotRef, lotUpdate);

        t.update(permissionRef, {
          lastBidAt: serverTs,
          bidRateWindowStartMs: windowStart,
          bidRateWindowCount: windowCount + 1,
          updatedAt: now,
        });

        const logRef = db.collection(LOGS).doc();
        t.set(logRef, {
          auctionId,
          lotId,
          action: "bid_placed",
          performedBy: uid,
          details: {
            bidId: clientRequestId,
            clientRequestId,
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
              bidId: clientRequestId,
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
          idempotent: false,
          outbidNotifyUid: shouldNotifyOutbid ? previousHighBidderId : null,
        };
      });

    if (outbidNotifyUid) {
      void sendAuctionOutbidNotification({
        recipientUid: outbidNotifyUid,
        auctionId,
        lotId,
      });
      void recordAuctionAnalyticsEvent(db, {
        eventType: AuctionAnalyticsEventType.USER_OUTBID,
        userId: outbidNotifyUid,
        lotId,
      });
    }

    if (idempotent !== true) {
      void recordAuctionAnalyticsEvent(db, {
        eventType: AuctionAnalyticsEventType.BID_PLACED,
        userId: uid,
        lotId,
      });
    }

    return {
      success: true,
      currentHighBid: newHighest,
      bidId: clientRequestId,
      antiSnipeExtended: extendedEnd,
      lotEndTimeMs: extendedEnd ? newEndTimeMs : null,
      idempotent: idempotent === true,
    };
  }
);
