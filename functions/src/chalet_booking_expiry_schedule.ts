/**
 * Cancels `pending_payment` bookings whose hold window has ended so dates free up * even if no new booking races occurred (complements in-query ignore of expired pendings).
 */
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { pendingPaymentStillHolds } from "./chalet_booking";

const BATCH_SAFE = 400;

export const cancelExpiredPendingBookings = onSchedule(
  {
    region: "us-central1",
    schedule: "every 5 minutes",
    timeZone: "Asia/Kuwait",
    memory: "256MiB",
  },
  async () => {
    const db = admin.firestore();
    const nowMs = Date.now();

    const snap = await db
      .collection("bookings")
      .where("status", "==", "pending_payment")
      .limit(500)
      .get();

    if (snap.empty) return;

    let batch = db.batch();
    let ops = 0;
    let cancelled = 0;

    for (const doc of snap.docs) {
      const d = doc.data();
      if (pendingPaymentStillHolds(d, nowMs)) continue;

      batch.update(doc.ref, {
        status: "cancelled",
        cancelledAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        cancelReason: "pending_payment_expired",
      });
      ops++;
      cancelled++;

      if (ops >= BATCH_SAFE) {
        await batch.commit();
        batch = db.batch();
        ops = 0;
      }
    }

    if (ops > 0) {
      await batch.commit();
    }

    if (cancelled > 0) {
      logger.info("cancelExpiredPendingBookings", { cancelled, scanned: snap.size });
    }
  }
);
