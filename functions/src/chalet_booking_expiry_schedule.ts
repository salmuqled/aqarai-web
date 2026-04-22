/**
 * Auto-cancellation sweeper for expired `pending_payment` chalet bookings.
 *
 * Invariants (production-critical):
 *   1. NEVER overwrite a `confirmed` booking. Every cancellation is guarded
 *      by an in-transaction re-read that aborts if the status was flipped
 *      to `confirmed` (or anything else) between the query and the write.
 *   2. NEVER cancel a booking whose hold window hasn't elapsed. We double-
 *      check [pendingPaymentStillHolds] inside the tx even though the query
 *      already filtered on `expiresAt < now` — this catches clock-skew and
 *      the legacy `createdAt + PENDING_PAYMENT_HOLD_MS` fallback.
 *   3. Idempotent: bookings already marked `isExpiredHandled: true` are
 *      skipped (fast-reject). Concurrent scheduler runs serialize on the
 *      Firestore tx and the second one aborts safely.
 *   4. No side-effects beyond the booking document itself — we don't send
 *      notifications, don't touch ledgers, don't call payment providers.
 *      Dates are released implicitly because overlap queries in
 *      [createBooking] filter on `status in [pending_payment, confirmed]`
 *      and `pendingPaymentStillHolds(...)` — a cancelled row drops out of
 *      both automatically.
 *
 * Domain naming: the codebase uses `"pending_payment"` (not the generic
 * `"pending"` from the spec) to distinguish booking-with-hold from any
 * future non-payment "pending" state. This is the established contract
 * referenced by Firestore rules, overlap checks, and the payment callables.
 */
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { pendingPaymentStillHolds } from "./chalet_booking";

/**
 * Per-invocation scan cap. At 1-minute cadence this clears up to 6,000
 * expired holds/hour — several orders of magnitude above realistic churn.
 * Kept well below Firestore's 500-write tx budget (each cancellation is a
 * single-doc tx, not a batch) and the scheduler's 540s timeout.
 */
const SCAN_LIMIT = 100;

export const cancelExpiredPendingBookings = onSchedule(
  {
    region: "us-central1",
    // Spec: run every 1 minute so worst-case exposure of a stale hold
    // (reserved dates a user can no longer pay for) stays ≤ 60 seconds.
    schedule: "every 1 minutes",
    timeZone: "Asia/Kuwait",
    memory: "256MiB",
  },
  async () => {
    const db = admin.firestore();
    const nowMs = Date.now();
    const nowTs = admin.firestore.Timestamp.fromMillis(nowMs);

    // Push the time filter into Firestore so we don't scan every open
    // booking on the platform. Requires the composite index
    // (status ASC, expiresAt ASC) added to firestore.indexes.json.
    //
    // Bookings missing `expiresAt` (pre-bookingVersion=1 legacy rows) are
    // naturally excluded here. They're > 5 min old at this point by
    // definition; if any still exist they can be swept by a one-off
    // admin script — we intentionally don't scan for them in the hot path.
    const snap = await db
      .collection("bookings")
      .where("status", "==", "pending_payment")
      .where("expiresAt", "<", nowTs)
      .limit(SCAN_LIMIT)
      .get();

    if (snap.empty) return;

    let cancelled = 0;
    let skippedAlreadyHandled = 0;
    let skippedStatusChanged = 0;
    let skippedStillHolding = 0;
    let txFailures = 0;

    // Process each row in its OWN transaction. Serial (not Promise.all) so
    // we don't starve Firestore with 100 concurrent tx on the same partition
    // — at ~100ms per tx this finishes in ~10s, well inside the 540s budget.
    for (const doc of snap.docs) {
      try {
        const outcome = await db.runTransaction(async (tx) => {
          const latest = await tx.get(doc.ref);
          if (!latest.exists) return "missing" as const;
          const d = latest.data()!;

          // GUARD #1: Idempotency — if another run already handled it, skip.
          // Can happen on scheduler overlap or manual retry.
          if (d.isExpiredHandled === true) {
            return "already_handled" as const;
          }

          // GUARD #2: Race with payment confirmation. This is THE critical
          // check. Between the query above and this transaction opening,
          // the MyFatoorah verification path or fake-pay path may have
          // already flipped status to "confirmed" inside its own tx —
          // Firestore serializes the two tx and we re-read the fresh state
          // here. Anything other than pending_payment aborts safely.
          if (d.status !== "pending_payment") {
            return "status_changed" as const;
          }

          // GUARD #3: Hold-window re-check. The query already filtered on
          // `expiresAt < now`, but this covers the legacy `createdAt +
          // PENDING_PAYMENT_HOLD_MS` fallback and guards against clock skew
          // between the function runtime and Firestore's server timestamps.
          if (pendingPaymentStillHolds(d, Date.now())) {
            return "still_holding" as const;
          }

          tx.update(doc.ref, {
            status: "cancelled",
            cancelReason: "timeout",
            cancelledAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            // Idempotency marker. Set once the cancellation is committed;
            // any future scheduler run sees this and fast-rejects via
            // GUARD #1 even before checking status.
            isExpiredHandled: true,
          });
          return "cancelled" as const;
        });

        switch (outcome) {
          case "cancelled":
            cancelled++;
            break;
          case "already_handled":
            skippedAlreadyHandled++;
            break;
          case "status_changed":
            skippedStatusChanged++;
            break;
          case "still_holding":
            skippedStillHolding++;
            break;
          case "missing":
            // Deleted mid-flight — nothing to do.
            break;
        }
      } catch (err) {
        // Firestore tx failures (contention, transient network) don't break
        // the sweep — next minute's run will retry any row that's still
        // `pending_payment` + `expiresAt < now`.
        txFailures++;
        logger.warn("cancelExpiredPendingBookings.tx_failed", {
          bookingId: doc.id,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    if (
      cancelled > 0 ||
      skippedStatusChanged > 0 ||
      skippedAlreadyHandled > 0 ||
      skippedStillHolding > 0 ||
      txFailures > 0
    ) {
      logger.info("cancelExpiredPendingBookings", {
        scanned: snap.size,
        cancelled,
        skippedAlreadyHandled,
        skippedStatusChanged,
        skippedStillHolding,
        txFailures,
      });
    }
  }
);
