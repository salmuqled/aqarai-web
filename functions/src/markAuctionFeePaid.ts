import * as admin from "firebase-admin";
import { randomUUID } from "crypto";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";

const AUCTION_REQUESTS = "auction_requests";

/**
 * Marks auction listing fee as paid after client completes checkout (mock or real gateway).
 * Authoritative: verifies ownership and pending status; sets paymentReference server-side.
 */
export const markAuctionFeePaid = onCall(
  { region: "us-central1" },
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

    const db = admin.firestore();
    const ref = db.collection(AUCTION_REQUESTS).doc(requestId);
    const paymentReference = `mock_${randomUUID()}`;

    await db.runTransaction(async (t) => {
      const snap = await t.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Auction request not found");
      }
      const data = snap.data()!;
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
      const fee = data.auctionFee;
      if (typeof fee !== "number" || !Number.isFinite(fee) || fee <= 0) {
        throw new HttpsError(
          "failed-precondition",
          "Invalid auction fee on request"
        );
      }

      t.update(ref, {
        auctionFeeStatus: "paid",
        auctionFeePaidAt: FieldValue.serverTimestamp(),
        paymentReference,
        updatedAt: FieldValue.serverTimestamp(),
      });
    });

    return { ok: true, paymentReference };
  }
);
