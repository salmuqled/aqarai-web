/**
 * Callable (admin): finalize a lot after endTime — sold + winner lock + audit log.
 * Requires Firebase custom claim admin AND Firestore `admins/{uid}` (active !== false).
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { runFinalizeLotTransaction } from "./auctionFinalizeCore";

const ADMINS = "admins";

async function assertAdminClaimAndDirectory(request: {
  auth?: { uid: string; token?: Record<string, unknown> };
}): Promise<string> {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Authentication required");
  }
  if (request.auth.token?.["admin"] !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
  const uid = request.auth.uid;
  const dir = await admin.firestore().collection(ADMINS).doc(uid).get();
  if (!dir.exists) {
    throw new HttpsError(
      "permission-denied",
      "Admin account is not listed in the admins directory"
    );
  }
  const active = dir.data()?.["active"];
  if (active === false) {
    throw new HttpsError(
      "permission-denied",
      "Admin directory entry is inactive"
    );
  }
  return uid;
}

export const finalizeLot = onCall(
  { region: "us-central1" },
  async (request) => {
    const adminUid = await assertAdminClaimAndDirectory(request);
    const data = request.data as Record<string, unknown> | undefined;
    const lotId =
      typeof data?.lotId === "string" ? data.lotId.trim() : "";
    if (!lotId) {
      throw new HttpsError("invalid-argument", "lotId is required");
    }

    const db = admin.firestore();
    const result = await runFinalizeLotTransaction(db, {
      lotId,
      performedBy: adminUid,
      nowMs: Date.now(),
      actorKind: "admin",
      enforceEndTimePassed: true,
    });

    return {
      success: true,
      ...result,
      winnerId: result.winnerUserId,
    };
  }
);
