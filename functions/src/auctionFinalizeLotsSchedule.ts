/**
 * Periodically finalizes lots that are still `active` but past `endsAt`.
 *
 * Note: Google Cloud Scheduler (Firebase scheduled functions) does not support
 * sub-minute intervals; the tightest practical schedule is once per minute.
 * For ~10s latency, use an external scheduler or Cloud Tasks at your own cost.
 */
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { Timestamp } from "firebase-admin/firestore";
import {
  LOTS,
  LOT_ACTIVE,
  runFinalizeLotTransaction,
} from "./auctionFinalizeCore";

const QUERY_LIMIT = 40;

export const finalizeExpiredAuctionLots = onSchedule(
  {
    region: "us-central1",
    schedule: "every 1 minutes",
    timeZone: "Asia/Kuwait",
    memory: "256MiB",
  },
  async () => {
    const db = admin.firestore();
    const now = Timestamp.fromMillis(Date.now());
    const snap = await db
      .collection(LOTS)
      .where("status", "==", LOT_ACTIVE)
      .where("endsAt", "<", now)
      .limit(QUERY_LIMIT)
      .get();

    if (snap.empty) return;

    for (const doc of snap.docs) {
      try {
        await runFinalizeLotTransaction(db, {
          lotId: doc.id,
          performedBy: "system",
          nowMs: Date.now(),
          actorKind: "system",
          enforceEndTimePassed: true,
        });
      } catch (e) {
        logger.warn("finalizeExpiredAuctionLots: skip/fail", {
          lotId: doc.id,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }
  }
);
