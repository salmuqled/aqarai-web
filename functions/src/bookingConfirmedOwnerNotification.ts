/**
 * Owner FCM notification: fires ONLY on the `pending_payment -> confirmed`
 * transition of `bookings/{bookingId}`.
 *
 * Why a Firestore trigger (and NOT inline inside the callable)?
 *   - `status: "confirmed"` is written server-side in [finalizeBookingAfterPayment]
 *     (chalet_booking.ts) which is the SINGLE writer for that transition.
 *     Running the notification out-of-band keeps the critical payment tx lean
 *     and guarantees the owner is only ever notified for bookings that
 *     actually made it to `confirmed` state — the tx either fully commits
 *     (including ledger writes) or rolls back, and this trigger runs only
 *     against the committed state.
 *
 * Safety invariants:
 *   1. Only fires on the EXACT transition (`before !== confirmed` &&
 *      `after === confirmed`). Any subsequent updates to a confirmed
 *      booking (admin edits, ledger denormalizations) are no-ops.
 *   2. Idempotent: a dedicated `ownerNotificationSent` flag is claimed
 *      inside a transaction before the FCM call, so even if Firebase
 *      retries the trigger (at-least-once delivery) the owner only gets
 *      one push. The flag + send timestamp is persisted on the booking
 *      doc for auditability.
 *   3. Never throws back to the runtime — all errors are logged. A failed
 *      notification MUST NOT cause the trigger to retry in a way that
 *      could re-attempt the (already-successful) payment flow.
 *
 * Failed / cancelled / expired bookings never reach `confirmed`, so this
 * trigger never fires for them by construction.
 */
import * as admin from "firebase-admin";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { FieldValue } from "firebase-admin/firestore";

import { propertyAreaArabicForNotification } from "./chalet_booking";
import { sendNotificationToUser } from "./sendUserNotification";

const db = admin.firestore();

export const onBookingConfirmedNotifyOwner = onDocumentUpdated(
  {
    document: "bookings/{bookingId}",
    region: "us-central1",
  },
  async (event) => {
    const bookingId = event.params.bookingId;
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!before || !after) return;

    const beforeStatus =
      typeof before.status === "string" ? before.status.trim() : "";
    const afterStatus =
      typeof after.status === "string" ? after.status.trim() : "";

    // GATE #1: only the pending_payment -> confirmed transition.
    // Ignore:
    //  - metadata edits on an already-confirmed booking (before=confirmed)
    //  - cancellations (after=cancelled)
    //  - expirations (after=cancelled via scheduler)
    //  - anything else that doesn't land in `confirmed`
    if (afterStatus !== "confirmed") return;
    if (beforeStatus === "confirmed") return;

    // GATE #2: fast-path duplicate check using the committed `after` state.
    // If another invocation already wrote the flag, abort before the tx.
    if (after.ownerNotificationSent === true) {
      console.info({
        tag: "booking.confirm.notify_owner.skipped",
        reason: "already_sent_fast_path",
        bookingId,
      });
      return;
    }

    const ownerId =
      typeof after.ownerId === "string" ? after.ownerId.trim() : "";
    const propertyId =
      typeof after.propertyId === "string" ? after.propertyId.trim() : "";
    if (!ownerId) {
      console.warn({
        tag: "booking.confirm.notify_owner.skipped",
        reason: "missing_owner",
        bookingId,
      });
      return;
    }

    // GATE #3: atomic claim. Two invocations racing here will both try the
    // same `get + check + update` pattern inside their own transactions;
    // Firestore serializes them, and the second one sees
    // `ownerNotificationSent === true` and bails via the sentinel error.
    // This is the authoritative duplicate guard — the fast-path check
    // above only exists to avoid paying for a doomed transaction.
    const bookingRef = db.collection("bookings").doc(bookingId);
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(bookingRef);
        if (!snap.exists) {
          throw new Error("missing");
        }
        const d = snap.data()!;
        if (d.status !== "confirmed") {
          throw new Error("status_changed");
        }
        if (d.ownerNotificationSent === true) {
          throw new Error("already_sent");
        }
        tx.update(bookingRef, {
          ownerNotificationSent: true,
          ownerNotificationSentAt: FieldValue.serverTimestamp(),
        });
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (
        msg === "already_sent" ||
        msg === "status_changed" ||
        msg === "missing"
      ) {
        console.info({
          tag: "booking.confirm.notify_owner.skipped",
          reason: msg,
          bookingId,
        });
        return;
      }
      // Unknown tx failure — don't crash; next invocation can retry safely
      // because the flag was not written.
      console.error({
        tag: "booking.confirm.notify_owner.claim_failed",
        bookingId,
        error: msg,
      });
      return;
    }

    // Load property for the Arabic area label. Best-effort: if it fails we
    // still send with the default "شاليهك" label rather than nothing, since
    // the flag above is already committed.
    let areaLabel = "شاليهك";
    if (propertyId) {
      try {
        const propSnap = await db
          .collection("properties")
          .doc(propertyId)
          .get();
        areaLabel = propertyAreaArabicForNotification(propSnap.data());
      } catch (e) {
        console.warn({
          tag: "booking.confirm.notify_owner.property_read_failed",
          bookingId,
          propertyId,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }

    try {
      await sendNotificationToUser({
        uid: ownerId,
        title: "تم تأكيد حجز جديد",
        body: `✅ تم استلام الدفع — تم تأكيد حجز جديد على شاليهك في ${areaLabel}`,
        notificationType: "booking",
        data: {
          screen: "booking",
          bookingId,
          propertyId,
          bookingAction: "confirmed",
        },
      });
      console.info({
        tag: "booking.confirm.notify_owner.sent",
        bookingId,
        ownerId,
      });
    } catch (e) {
      // `sendNotificationToUser` already swallows per-token FCM errors;
      // anything reaching here is an unexpected runtime exception. Log and
      // continue — flag is already claimed, retrying won't help.
      console.error({
        tag: "booking.confirm.notify_owner.send_failed",
        bookingId,
        error: e instanceof Error ? e.message : String(e),
      });
    }
  }
);
