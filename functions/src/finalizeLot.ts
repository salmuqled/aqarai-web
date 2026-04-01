/**
 * Callable (admin): finalize a lot after endsAt.
 * With bids: moves to `pending_admin_review` (no winner until seller + admin approve).
 * Without bids: `closed`. Requires admin claim + `admins/{uid}`.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { assertAdminClaimAndDirectory } from "./auctionAdminAuth";
import { runFinalizeLotTransaction } from "./auctionFinalizeCore";

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
