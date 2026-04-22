/**
 * Shared Firestore availability primitives.
 *
 * This module is the single source of truth for:
 *   - Parsing ISO / millis / Firestore-Timestamp-POJO / Timestamp inputs into
 *     `admin.firestore.Timestamp` (`parseIsoToTimestamp`).
 *   - Half-open interval overlap detection `[startA,endA) ∩ [startB,endB)`
 *     (`rangesOverlapHalfOpen`).
 *   - Honoring the 5-minute `pending_payment` hold window on `bookings`
 *     (`pendingPaymentHoldStillHolds`).
 *   - The batched "fetch unavailable property IDs over a date range" primitive
 *     used by both the daily-rent marketplace (`searchDailyProperties`) and the
 *     AI chat pipeline (`filterChatAvailability`)
 *     (`fetchUnavailablePropertyIdsBatched`).
 *
 * Moving these here eliminated a prior duplication risk: previously the
 * helpers lived inside `index.ts` as module-private functions and could not be
 * reused without rewriting overlap logic elsewhere. Any new availability
 * consumer (chat, concierge, notifications, scheduled cleanup) MUST import
 * from here rather than re-implement interval math.
 *
 * This file intentionally does NOT contain any callable / trigger — it is a
 * pure library so it can be imported from any function file without import
 * side effects.
 */
import * as admin from "firebase-admin";

/**
 * Firestore `IN` clause limit for `propertyId`. Kept aligned with
 * `isDateRangeAvailable` style usage across the codebase.
 */
export const AVAILABILITY_PROPERTY_ID_IN_CHUNK = 30;

/**
 * Pending-payment hold window. Must stay aligned with the chalet booking
 * `pending_payment` TTL enforced by `functions/src/chalet_booking.ts`.
 */
export const PENDING_PAYMENT_HOLD_MS = 5 * 60 * 1000;

/**
 * True iff a `pending_payment` booking doc still has its 5-minute hold active.
 * Order of precedence:
 *   1. `expiresAt` Timestamp (authoritative; written by `createBooking`).
 *   2. `createdAt + HOLD_MS` fallback for legacy rows with no `expiresAt`.
 *   3. Treat as still-holding if neither exists (fail-safe: blocks overlaps
 *      so we never show a chalet as available when data integrity is in doubt).
 */
export function pendingPaymentHoldStillHolds(
  data: admin.firestore.DocumentData,
  nowMs: number
): boolean {
  const st = typeof data.status === "string" ? data.status.trim() : "";
  if (st !== "pending_payment") return false;
  const exp = data.expiresAt;
  if (exp instanceof admin.firestore.Timestamp) {
    return exp.toMillis() > nowMs;
  }
  const cr = data.createdAt;
  if (cr instanceof admin.firestore.Timestamp) {
    return cr.toMillis() + PENDING_PAYMENT_HOLD_MS > nowMs;
  }
  return true;
}

/**
 * Half-open interval overlap: `[startA, endA) ∩ [startB, endB) ≠ ∅`.
 *
 * This matches the hotel contract used everywhere in the app: `endDate` is the
 * *exclusive* check-out day. Two back-to-back bookings (A ends on day X,
 * B starts on day X) do NOT overlap.
 */
export function rangesOverlapHalfOpen(
  startA: admin.firestore.Timestamp,
  endA: admin.firestore.Timestamp,
  startB: admin.firestore.Timestamp,
  endB: admin.firestore.Timestamp
): boolean {
  return startA.toMillis() < endB.toMillis() && endA.toMillis() > startB.toMillis();
}

/**
 * Lenient date-ish -> Firestore Timestamp coercion. Accepts:
 *   - `admin.firestore.Timestamp`
 *   - A Timestamp POJO `{ seconds, nanoseconds? }` (from client SDK round-trips).
 *   - Millisecond epoch numbers.
 *   - ISO-8601 strings (including the `toISOString()` output of the Date
 *     Intelligence Layer).
 * Returns null for anything else (including empty string / null / NaN).
 */
export function parseIsoToTimestamp(v: unknown): admin.firestore.Timestamp | null {
  if (v == null || v === "") return null;
  if (v instanceof admin.firestore.Timestamp) return v;
  if (typeof v === "object" && v !== null && "seconds" in (v as object)) {
    const o = v as { seconds: number; nanoseconds?: number };
    if (typeof o.seconds === "number") {
      return new admin.firestore.Timestamp(o.seconds, o.nanoseconds ?? 0);
    }
  }
  if (typeof v === "number" && !Number.isNaN(v) && Number.isFinite(v)) {
    return admin.firestore.Timestamp.fromMillis(Math.trunc(v));
  }
  if (typeof v === "string") {
    const ms = Date.parse(v);
    if (!Number.isNaN(ms)) return admin.firestore.Timestamp.fromMillis(ms);
  }
  return null;
}

/**
 * For a set of property IDs and a request window `[reqStart, reqEnd)`, return
 * the subset of IDs that are UNAVAILABLE because they overlap either:
 *   - an active `confirmed` / still-holding `pending_payment` booking, OR
 *   - a `blocked_dates` range.
 *
 * This primitive is shared by `searchDailyProperties` (marketplace page) and
 * `filterChatAvailability` (AI chat). Chunking respects Firestore's `IN`
 * clause limit via [AVAILABILITY_PROPERTY_ID_IN_CHUNK].
 *
 * Complexity: one `blocked_dates` + one `bookings` query per chunk of 30 IDs.
 * For a typical chat batch of ≤ 120 candidate listings that is 8 queries
 * total, running in parallel per chunk.
 */
export async function fetchUnavailablePropertyIdsBatched(
  db: admin.firestore.Firestore,
  propertyIds: string[],
  reqStart: admin.firestore.Timestamp,
  reqEnd: admin.firestore.Timestamp,
  nowMs: number
): Promise<Set<string>> {
  const out = new Set<string>();
  if (propertyIds.length === 0) return out;

  for (let i = 0; i < propertyIds.length; i += AVAILABILITY_PROPERTY_ID_IN_CHUNK) {
    const chunk = propertyIds.slice(i, i + AVAILABILITY_PROPERTY_ID_IN_CHUNK);
    const [blocksSnap, bookingsSnap] = await Promise.all([
      db
        .collection("blocked_dates")
        .where("propertyId", "in", chunk)
        .where("startDate", "<=", reqEnd)
        .get(),
      db.collection("bookings").where("propertyId", "in", chunk).get(),
    ]);

    for (const doc of blocksSnap.docs) {
      const d = doc.data();
      const pid = typeof d.propertyId === "string" ? d.propertyId : "";
      const bs = d.startDate as admin.firestore.Timestamp | undefined;
      const be = d.endDate as admin.firestore.Timestamp | undefined;
      if (!pid || !bs || !be) continue;
      if (rangesOverlapHalfOpen(reqStart, reqEnd, bs, be)) out.add(pid);
    }

    for (const doc of bookingsSnap.docs) {
      const d = doc.data();
      const pid = typeof d.propertyId === "string" ? d.propertyId : "";
      const st = typeof d.status === "string" ? d.status.trim() : "";
      if (st !== "pending_payment" && st !== "confirmed") continue;
      if (st === "pending_payment" && !pendingPaymentHoldStillHolds(d, nowMs)) continue;
      const bs = d.startDate as admin.firestore.Timestamp | undefined;
      const be = d.endDate as admin.firestore.Timestamp | undefined;
      if (!pid || !bs || !be) continue;
      if (rangesOverlapHalfOpen(reqStart, reqEnd, bs, be)) out.add(pid);
    }
  }
  return out;
}
