/**
 * Callable: exactly one deposit document per user per lot (Admin SDK + transaction).
 * Document ID: `${uid}_${lotId}`.
 * If the document exists (any paymentStatus), returns it and performs no write.
 * Otherwise creates: userId, lotId, auctionId, paymentStatus pending, createdAt.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";

const LOTS = "lots";
const DEPOSITS = "deposits";

const STATUS_PENDING = "pending";

function userLotDepositId(uid: string, lotId: string): string {
  return `${uid}_${lotId}`;
}

function assertAuthed(request: { auth?: { uid: string } | undefined }): string {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Authentication required");
  }
  return request.auth.uid;
}

export const createAuctionDeposit = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = assertAuthed(request);
    const data = request.data as Record<string, unknown> | undefined;
    const auctionId =
      typeof data?.auctionId === "string" ? data.auctionId.trim() : "";
    const lotId = typeof data?.lotId === "string" ? data.lotId.trim() : "";

    if (!auctionId) {
      throw new HttpsError("invalid-argument", "auctionId is required");
    }
    if (!lotId) {
      throw new HttpsError("invalid-argument", "lotId is required");
    }

    const db = admin.firestore();
    const depositId = userLotDepositId(uid, lotId);
    const depRef = db.collection(DEPOSITS).doc(depositId);
    const lotRef = db.collection(LOTS).doc(lotId);

    const out = await db.runTransaction(async (t) => {
      const depSnap = await t.get(depRef);
      const lotSnap = await t.get(lotRef);

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

      if (depSnap.exists) {
        return { depositId, existing: true as const };
      }

      t.set(depRef, {
        userId: uid,
        lotId,
        auctionId,
        paymentStatus: STATUS_PENDING,
        createdAt: FieldValue.serverTimestamp(),
      });

      return { depositId, existing: false as const };
    });

    return out;
  }
);
