/**
 * ONE-TIME ADMIN CLEANUP: legacy `pending_payment` bookings that have no
 * `expiresAt` field and were created more than 10 minutes ago.
 *
 * CONTEXT
 *   The scheduled sweeper [cancelExpiredPendingBookings] pushes its time
 *   filter into Firestore (`where("expiresAt", "<", nowTs)`) which
 *   NATURALLY EXCLUDES legacy docs that were written before
 *   `bookingVersion: 1` (i.e. before `expiresAt` was being set on create).
 *   Those rows get stuck in `pending_payment` forever and keep blocking the
 *   same date range for other bookings. This script sweeps them in one
 *   manual pass.
 *
 * INVARIANTS (production-critical)
 *   1. NEVER touch a booking that is not `pending_payment` at commit time.
 *      Every cancellation runs inside a per-doc transaction that re-reads
 *      the doc right before writing. If a legacy row somehow confirms
 *      between our query and our commit (a stretch, but possible if this
 *      is re-run), the tx aborts and we return "status_changed".
 *   2. NEVER cancel a recent booking. The 10-minute age floor is checked
 *      both pre-tx (fast-reject) AND inside the tx (defense-in-depth).
 *   3. NEVER cancel a booking that already has `expiresAt`. Such docs are
 *      modern — they belong to the scheduled sweeper's jurisdiction, not
 *      this one.
 *   4. Idempotent. Re-running is safe: rows we already cancelled have
 *      `status: "cancelled"` and are rejected by GUARD #1.
 *
 * EXECUTION
 *   This is deployed as an admin-gated HTTPS callable so it can be invoked
 *   from `firebase functions:shell`:
 *
 *     cleanupLegacyPendingBookings({ dryRun: true })
 *     cleanupLegacyPendingBookings({ dryRun: false })
 *
 *   Or from a trusted admin script with a custom-claims admin token. The
 *   callable returns a structured summary so you can verify the dry-run
 *   output before flipping `dryRun: false`.
 *
 *   Safety default: DRY_RUN is `true`. The dryRun request param is optional
 *   and defaults to the file-level constant. To actually write, you MUST
 *   either flip the constant to `false` in a deploy, OR pass
 *   `{ dryRun: false }` in the callable payload.
 */
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

/** Safety default. Flip to `false` AFTER reviewing dry-run output. */
const DRY_RUN = true;

/** Minimum age before a legacy `pending_payment` row is eligible for cleanup. */
const LEGACY_AGE_FLOOR_MS = 10 * 60 * 1000;

/**
 * Hard cap on docs processed per invocation. Transactions are serial so
 * each call comfortably finishes inside the 60s `onCall` budget even at
 * the cap (roughly 100-200ms per tx). Admin re-runs until `hasMore: false`.
 */
const MAX_PAGE_SIZE = 500;
const DEFAULT_PAGE_SIZE = 300;

function isAdmin(token?: Record<string, unknown>): boolean {
  if (!token) return false;
  const a = token.admin;
  return a === true || a === "true";
}

export const cleanupLegacyPendingBookings = onCall(
  { region: "us-central1", timeoutSeconds: 60 },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    if (!isAdmin(request.auth.token)) {
      throw new HttpsError("permission-denied", "Admin only");
    }

    const data = (request.data ?? {}) as Record<string, unknown>;

    // Honor the per-call override when present; otherwise use the safer
    // file-level default. Explicit `false` flips to real writes; anything
    // else (missing, true, non-boolean) stays in dry-run.
    const dryRun = typeof data.dryRun === "boolean" ? data.dryRun : DRY_RUN;

    const rawPageSize =
      typeof data.pageSize === "number" && Number.isFinite(data.pageSize)
        ? Math.trunc(data.pageSize)
        : DEFAULT_PAGE_SIZE;
    const pageSize = Math.max(1, Math.min(MAX_PAGE_SIZE, rawPageSize));

    const db = admin.firestore();
    const nowMs = Date.now();
    const ageFloorTs = admin.firestore.Timestamp.fromMillis(
      nowMs - LEGACY_AGE_FLOOR_MS
    );

    // Scan `pending_payment` rows. We can't push "expiresAt missing" into
    // the query (Firestore has no "field not exists" filter), so filtering
    // happens in code. To keep the read budget bounded we cap the page at
    // [pageSize] and let the admin call us again until `hasMore` is false.
    const snap = await db
      .collection("bookings")
      .where("status", "==", "pending_payment")
      .limit(pageSize)
      .get();

    let eligible = 0;
    let cancelled = 0;
    let wouldCancel = 0;
    let skippedHasExpiresAt = 0;
    let skippedMissingCreatedAt = 0;
    let skippedTooRecent = 0;
    let skippedAlreadyHandled = 0;
    let skippedStatusChanged = 0;
    let skippedExpiresAtAppeared = 0;
    let txFailures = 0;

    for (const doc of snap.docs) {
      const d = doc.data();

      // GUARD #A (fast-reject): modern docs have `expiresAt` — not our job.
      // The scheduled sweeper handles them.
      if (d.expiresAt != null) {
        skippedHasExpiresAt++;
        continue;
      }

      // GUARD #B: need a server-provided createdAt to compute age.
      const createdAt = d.createdAt;
      if (!(createdAt instanceof admin.firestore.Timestamp)) {
        skippedMissingCreatedAt++;
        logger.info("cleanupLegacyPendingBookings.skip.no_createdAt", {
          bookingId: doc.id,
        });
        continue;
      }

      // GUARD #C: minimum age floor — don't touch anything younger than
      // 10 minutes, even if somehow missing `expiresAt` (shouldn't happen
      // post-bookingVersion=1, but this is defense-in-depth).
      if (createdAt.toMillis() >= ageFloorTs.toMillis()) {
        skippedTooRecent++;
        continue;
      }

      eligible++;

      // DRY-RUN branch: log the intent, do NOT write.
      if (dryRun) {
        wouldCancel++;
        logger.info("cleanupLegacyPendingBookings.dry_run.would_cancel", {
          bookingId: doc.id,
          propertyId: d.propertyId ?? null,
          ownerId: d.ownerId ?? null,
          clientId: d.clientId ?? null,
          createdAtMs: createdAt.toMillis(),
          ageMinutes: Math.round(
            (nowMs - createdAt.toMillis()) / 60000
          ),
        });
        continue;
      }

      // REAL-WRITE branch: per-doc transaction. Re-verify everything from
      // the fresh snapshot because the pre-tx read happened on the query
      // snapshot which may be seconds stale.
      try {
        const outcome = await db.runTransaction(async (tx) => {
          const latest = await tx.get(doc.ref);
          if (!latest.exists) return "missing" as const;
          const cur = latest.data()!;

          // Idempotency guard — if a previous run (or the scheduled sweeper)
          // already handled it, do nothing.
          if (cur.isExpiredHandled === true) {
            return "already_handled" as const;
          }

          // Status may have flipped to `confirmed` or `cancelled` between
          // the query above and this tx. Re-reading here is the ONLY way
          // to guarantee we don't overwrite a paid booking.
          if (cur.status !== "pending_payment") {
            return "status_changed" as const;
          }

          // Someone / something may have backfilled `expiresAt` between
          // our pre-tx check and now (e.g. a concurrent migration). If
          // so, this doc is no longer "legacy" — let the scheduled
          // sweeper handle it instead.
          if (cur.expiresAt != null) {
            return "expiresAt_appeared" as const;
          }

          // Re-check the age floor from the FRESH createdAt.
          const curCreatedAt = cur.createdAt;
          if (
            !(curCreatedAt instanceof admin.firestore.Timestamp) ||
            curCreatedAt.toMillis() >= ageFloorTs.toMillis()
          ) {
            return "too_recent" as const;
          }

          tx.update(doc.ref, {
            status: "cancelled",
            cancelReason: "legacy_timeout",
            cancelledAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
            isExpiredHandled: true,
          });
          return "cancelled" as const;
        });

        switch (outcome) {
          case "cancelled":
            cancelled++;
            logger.info("cleanupLegacyPendingBookings.cancelled", {
              bookingId: doc.id,
              propertyId: d.propertyId ?? null,
            });
            break;
          case "already_handled":
            skippedAlreadyHandled++;
            break;
          case "status_changed":
            skippedStatusChanged++;
            logger.info("cleanupLegacyPendingBookings.skip.status_changed", {
              bookingId: doc.id,
            });
            break;
          case "expiresAt_appeared":
            skippedExpiresAtAppeared++;
            break;
          case "too_recent":
            skippedTooRecent++;
            break;
          case "missing":
            // Deleted mid-flight — nothing to do.
            break;
        }
      } catch (err) {
        txFailures++;
        logger.warn("cleanupLegacyPendingBookings.tx_failed", {
          bookingId: doc.id,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }

    const summary = {
      dryRun,
      pageSize,
      scanned: snap.size,
      eligible,
      cancelled,
      wouldCancel,
      skippedHasExpiresAt,
      skippedMissingCreatedAt,
      skippedTooRecent,
      skippedAlreadyHandled,
      skippedStatusChanged,
      skippedExpiresAtAppeared,
      txFailures,
      // `hasMore === true` means there may be more legacy rows to sweep:
      // the `pending_payment` page was full. Call again until this is
      // false. (False doesn't PROVE zero remaining — it just means this
      // page was under-full — but in practice legacy rows live in a
      // bounded tail, so a single non-full page is the end of the road.)
      hasMore: snap.size === pageSize,
    };

    logger.info("cleanupLegacyPendingBookings.summary", summary);
    return summary;
  }
);
