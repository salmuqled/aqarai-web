import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";

import {
  myFatoorahGetPaymentStatusFlexible,
  rejectIfMockPaymentId,
} from "./payments/myfatoorahVerify";
import { myFatoorahApiKey } from "./payments/myfatoorahRuntime";
import { AUCTION_LISTING_FEE_KWD } from "./payments/pricing";

const AUCTION_REQUESTS = "auction_requests";

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

/**
 * Marks an auction listing fee as paid AFTER server-side MyFatoorah
 * verification. Authoritative path:
 *
 *   client → MyFatoorah checkout → app receives `paymentId`
 *           → calls this with { requestId, paymentId }
 *
 * The server:
 *   1. Rejects mock/fake/simulate payment ids.
 *   2. Calls MyFatoorah `GetPaymentStatus` (server-side; never trust client).
 *   3. Verifies `status=paid`, `currency=KWD`, `amount==AUCTION_LISTING_FEE_KWD`.
 *   4. Atomically:
 *        - claims `payment_logs/{paymentId}` (idempotency),
 *        - flips the auction request to `auctionFeeStatus: "paid"`,
 *        - records the gateway reference + canonical fee on the request.
 *
 * Replay-safe: the claim doc id is the gateway paymentId, so a single
 * paymentId can never finalize two different auction requests, and a retry
 * for the same request after a network blip is rejected with
 * `already-exists` instead of double-charging.
 */
export const markAuctionFeePaid = onCall(
  { region: "us-central1", secrets: [myFatoorahApiKey] },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    const uid = request.auth.uid;

    const requestId =
      typeof request.data?.requestId === "string"
        ? request.data.requestId.trim()
        : "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId is required");
    }

    const paymentId =
      typeof request.data?.paymentId === "string"
        ? request.data.paymentId.trim()
        : "";
    if (!paymentId) {
      throw new HttpsError("invalid-argument", "paymentId is required");
    }
    rejectIfMockPaymentId(paymentId);

    // 1) Verify with MyFatoorah BEFORE touching Firestore.
    const ver = await myFatoorahGetPaymentStatusFlexible(paymentId);
    if (!ver.ok) {
      throw new HttpsError(
        "failed-precondition",
        ver.status === "disabled"
          ? "Payment system not configured yet"
          : `Payment not successful (${ver.status})`
      );
    }
    if ((ver.currency ?? "").toUpperCase() !== "KWD") {
      throw new HttpsError("failed-precondition", "Currency must be KWD");
    }
    if (ver.amountKwd == null) {
      throw new HttpsError(
        "failed-precondition",
        "Missing paid amount from gateway"
      );
    }
    const paid = round3(ver.amountKwd);
    const fee = round3(AUCTION_LISTING_FEE_KWD);
    if (paid < fee - 0.0001 || paid > fee + 2) {
      throw new HttpsError(
        "failed-precondition",
        `Paid amount mismatch (expected about ${AUCTION_LISTING_FEE_KWD} KWD)`
      );
    }

    // 2) Atomic write: idempotency claim + auction_request flip.
    const db = admin.firestore();
    const requestRef = db.collection(AUCTION_REQUESTS).doc(requestId);
    const claimRef = db.collection("payment_logs").doc(paymentId);

    await db.runTransaction(async (t) => {
      const [reqSnap, claimSnap] = await Promise.all([
        t.get(requestRef),
        t.get(claimRef),
      ]);

      if (claimSnap.exists) {
        throw new HttpsError("already-exists", "paymentId already used");
      }
      if (!reqSnap.exists) {
        throw new HttpsError("not-found", "Auction request not found");
      }

      const data = reqSnap.data()!;
      if (String(data.userId ?? "") !== uid) {
        throw new HttpsError(
          "permission-denied",
          "You do not own this request"
        );
      }
      const status = String(data.auctionFeeStatus ?? "");
      if (status !== "pending") {
        throw new HttpsError(
          "failed-precondition",
          status === "paid"
            ? "Fee already paid"
            : `Fee cannot be marked paid (${status || "unknown"})`
        );
      }

      // Canonical fee guard: server overwrites whatever sat on the doc.
      // The rules also pin auctionFee == AUCTION_LISTING_FEE_KWD on create.
      const fee = data.auctionFee;
      if (
        typeof fee !== "number" ||
        !Number.isFinite(fee) ||
        round3(fee) !== round3(AUCTION_LISTING_FEE_KWD)
      ) {
        throw new HttpsError(
          "failed-precondition",
          `Auction fee on request must be ${AUCTION_LISTING_FEE_KWD} KWD`
        );
      }

      t.update(requestRef, {
        auctionFeeStatus: "paid",
        auctionFeePaidAt: FieldValue.serverTimestamp(),
        auctionFee: AUCTION_LISTING_FEE_KWD,
        paymentReference: paymentId,
        paymentGatewayReference: ver.reference,
        paymentGatewayStatus: ver.status,
        updatedAt: FieldValue.serverTimestamp(),
      });

      t.set(claimRef, {
        paymentId,
        action: "auction_fee_payment",
        newStatus: "success",
        performedBy: uid,
        timestamp: FieldValue.serverTimestamp(),
        verified: true,
        gateway: "MyFatoorah",
        paymentMode: "production",
        relatedType: "auction_request",
        relatedId: requestId,
        amountKwd: AUCTION_LISTING_FEE_KWD,
        currency: "KWD",
        gatewayReference: ver.reference,
      });
    });

    return {
      ok: true,
      paymentReference: paymentId,
      amountKwd: AUCTION_LISTING_FEE_KWD,
    };
  }
);
