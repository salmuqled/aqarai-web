/**
 * Chalet bookings: authoritative overlap checks and creates only via callable (no client writes).
 *
 * Overlap rule (confirmed bookings only): (startA < endB) && (endA > startB)
 *
 * Example document:
 * {
 *   "propertyId": "abc123",
 *   "ownerId": "ownerUid",
 *   "clientId": "clientUid",
 *   "startDate": Timestamp,
 *   "endDate": Timestamp,
 *   "status": "pending",
 *   "pricePerNight": 80,
 *   "currency": "KWD",
 *   "totalPrice": 240,
 *   "daysCount": 3,
 *   "createdAt": Timestamp (server),
 *   "confirmedAt": Timestamp (only after confirm — optional on legacy reads),
 *   "bookingVersion": 1 (optional on newer creates)
 * }
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { createTransactionFromConfirmedBooking } from "./chalet_booking_finance";
import { sendNotificationToUser } from "./sendUserNotification";

const db = admin.firestore();

// TODO: Remove legacyEvent after dashboards and alerts are updated (e.g. after 2–4 weeks)
/** Prior `event` values for monitoring during transition; drop this field when the TODO above is done. */
const BOOKING_LOG_LEGACY_EVENT = {
  availabilityCheck: "check_booking_availability",
  bookingAttempt: "booking_attempt",
  bookingError: "booking_error",
} as const;

/** Fixed facet for analytics / BigQuery filters (all chalet booking logs). */
const BOOKING_LOG_CATEGORY = "booking" as const;

/** Pairs with `event` one-to-one for dashboards. */
const BOOKING_LOG_ACTION = {
  availabilityCheck: "availability_check",
  createAttempt: "create_attempt",
  confirmAttempt: "confirm_attempt",
  error: "error",
} as const;

export type BookingStatus = "pending" | "confirmed" | "cancelled";

/** Optional UX / debug field on [checkBookingAvailability] when [available] is false. */
export type CheckBookingAvailabilityReason =
  | "not_bookable"
  | "not_daily_chalet"
  | "overlap"
  | "invalid_dates";

/**
 * `bookings/{id}` shape. Older documents may omit `pricePerNight` / `currency` / `confirmedAt`.
 * Client code must treat those fields as optional.
 */
export interface ChaletBookingDocument {
  propertyId: string;
  ownerId: string;
  clientId: string;
  startDate: admin.firestore.Timestamp;
  endDate: admin.firestore.Timestamp;
  status: BookingStatus;
  /** Frozen at create; legacy bookings may be missing. */
  pricePerNight?: number;
  /** ISO-like code; legacy bookings may be missing (clients default e.g. KWD). */
  currency?: string;
  totalPrice: number;
  daysCount: number;
  createdAt?: admin.firestore.Timestamp;
  /** Set only when status becomes confirmed; omit on create and when pending. */
  confirmedAt?: admin.firestore.Timestamp;
  /** Optional schema marker for newer writes; omit on legacy documents. */
  bookingVersion?: number;
}

function bookingAlreadyHasConfirmedAt(data: admin.firestore.DocumentData): boolean {
  const v = data.confirmedAt;
  if (v == null) return false;
  if (v instanceof admin.firestore.Timestamp) return true;
  return typeof v === "object" && v !== null && "seconds" in v;
}

function requireUid(request: { auth?: { uid?: string } }): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }
  return uid;
}

/** Matches Firestore rules: boolean true or legacy string "true". */
function isAdminAuth(auth: { token?: Record<string, unknown> } | undefined): boolean {
  if (!auth?.token) return false;
  const a = auth.token.admin;
  return a === true || a === "true";
}

export function rangesOverlap(
  startA: admin.firestore.Timestamp,
  endA: admin.firestore.Timestamp,
  startB: admin.firestore.Timestamp,
  endB: admin.firestore.Timestamp
): boolean {
  return startA.toMillis() < endB.toMillis() && endA.toMillis() > startB.toMillis();
}

/** Short area label for FCM body (Arabic-first, then EN / legacy `area`). */
function propertyAreaArabicForNotification(
  pdata: admin.firestore.DocumentData | undefined
): string {
  if (!pdata) return "شاليهك";
  const ar = String(pdata.areaAr ?? "").trim();
  if (ar.length > 0) return ar.slice(0, 80);
  const en = String(pdata.areaEn ?? pdata.area ?? "").trim();
  if (en.length > 0) return en.slice(0, 80);
  return "شاليهك";
}

function parseRequestTimestamp(v: unknown): admin.firestore.Timestamp | null {
  if (v == null || v === "") return null;
  if (v instanceof admin.firestore.Timestamp) return v;
  if (typeof v === "object" && v !== null && "seconds" in v) {
    const o = v as { seconds: number; nanoseconds?: number };
    if (typeof o.seconds === "number") {
      return new admin.firestore.Timestamp(o.seconds, o.nanoseconds ?? 0);
    }
  }
  if (typeof v === "number" && !Number.isNaN(v)) {
    return admin.firestore.Timestamp.fromMillis(Math.trunc(v));
  }
  if (typeof v === "string") {
    const ms = Date.parse(v);
    if (!Number.isNaN(ms)) return admin.firestore.Timestamp.fromMillis(ms);
  }
  return null;
}

/** Matches app [effectiveChaletMode]: missing/invalid → daily. */
export function effectiveChaletMode(data: admin.firestore.DocumentData | undefined): string {
  if (!data || data.listingCategory !== "chalet") return "";
  const raw = String(data.chaletMode ?? "").trim().toLowerCase();
  if (!raw) return "daily";
  if (raw === "daily" || raw === "monthly" || raw === "sale") return raw;
  return "daily";
}

function chaletPropertyBookable(data: admin.firestore.DocumentData | undefined): {
  ok: boolean;
  ownerId: string;
  pricePerNight: number;
} {
  if (!data) return { ok: false, ownerId: "", pricePerNight: 0 };
  if (data.listingCategory !== "chalet") return { ok: false, ownerId: "", pricePerNight: 0 };
  if (effectiveChaletMode(data) !== "daily") return { ok: false, ownerId: "", pricePerNight: 0 };
  if (data.approved !== true) return { ok: false, ownerId: "", pricePerNight: 0 };
  const owner = data.ownerId;
  if (typeof owner !== "string" || !owner.trim()) return { ok: false, ownerId: "", pricePerNight: 0 };
  const price =
    typeof data.price === "number" ? data.price : Number(data.price);
  if (!Number.isFinite(price) || price <= 0) return { ok: false, ownerId: "", pricePerNight: 0 };
  return { ok: true, ownerId: owner.trim(), pricePerNight: price };
}

function computeDaysCount(
  start: admin.firestore.Timestamp,
  end: admin.firestore.Timestamp
): number {
  const ms = end.toMillis() - start.toMillis();
  if (ms <= 0) return 0;
  const day = 86400000;
  return Math.max(1, Math.ceil(ms / day));
}

/**
 * UI / pre-check only. Final authority is [createBooking].
 */
export async function isDateRangeAvailable(
  propertyId: string,
  start: admin.firestore.Timestamp,
  end: admin.firestore.Timestamp
): Promise<boolean> {
  const trimmed = propertyId?.trim();
  if (!trimmed) return false;
  if (start.toMillis() >= end.toMillis()) return false;

  const snap = await db
    .collection("bookings")
    .where("propertyId", "==", trimmed)
    .where("status", "==", "confirmed")
    .get();

  for (const doc of snap.docs) {
    const d = doc.data();
    const bs = d.startDate as admin.firestore.Timestamp | undefined;
    const be = d.endDate as admin.firestore.Timestamp | undefined;
    if (!bs || !be) continue;
    if (rangesOverlap(start, end, bs, be)) return false;
  }
  return true;
}

/** Use inside catch blocks for non-client failures (Firestore, unexpected runtime). */
function logBookingError(err: unknown, propertyId: string): void {
  const e = err instanceof Error ? err : null;
  console.error({
    event: "booking.error",
    legacyEvent: BOOKING_LOG_LEGACY_EVENT.bookingError,
    category: BOOKING_LOG_CATEGORY,
    action: BOOKING_LOG_ACTION.error,
    propertyId,
    error: e?.message,
    stack: e?.stack,
  });
}

/**
 * Optional UI pre-check; [createBooking] always re-validates in a transaction.
 */
export const checkBookingAvailability = onCall(
  { region: "us-central1" },
  async (request) => {
    const propertyId =
      typeof request.data?.propertyId === "string" ? request.data.propertyId.trim() : "";
    const start = parseRequestTimestamp(request.data?.startDate);
    const end = parseRequestTimestamp(request.data?.endDate);

    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId is required");
    }

    try {
      if (!start || !end) {
        const reason = "invalid_dates" satisfies CheckBookingAvailabilityReason;
        console.warn({
          event: "booking.availability.check",
          legacyEvent: BOOKING_LOG_LEGACY_EVENT.availabilityCheck,
          category: BOOKING_LOG_CATEGORY,
          action: BOOKING_LOG_ACTION.availabilityCheck,
          propertyId,
          result: "blocked",
          reason,
        });
        return { available: false, reason };
      }
      if (start.toMillis() === end.toMillis()) {
        const reason = "invalid_dates" satisfies CheckBookingAvailabilityReason;
        console.warn({
          event: "booking.availability.check",
          legacyEvent: BOOKING_LOG_LEGACY_EVENT.availabilityCheck,
          category: BOOKING_LOG_CATEGORY,
          action: BOOKING_LOG_ACTION.availabilityCheck,
          propertyId,
          result: "blocked",
          reason,
        });
        return { available: false, reason };
      }
      if (start.toMillis() > end.toMillis()) {
        const reason = "invalid_dates" satisfies CheckBookingAvailabilityReason;
        console.warn({
          event: "booking.availability.check",
          legacyEvent: BOOKING_LOG_LEGACY_EVENT.availabilityCheck,
          category: BOOKING_LOG_CATEGORY,
          action: BOOKING_LOG_ACTION.availabilityCheck,
          propertyId,
          result: "blocked",
          reason,
        });
        return { available: false, reason };
      }

      const propSnap = await db.collection("properties").doc(propertyId).get();
      const pdata = propSnap.data();
      if (!pdata || pdata.listingCategory !== "chalet") {
        const reason = "not_bookable" satisfies CheckBookingAvailabilityReason;
        console.warn({
          event: "booking.availability.check",
          legacyEvent: BOOKING_LOG_LEGACY_EVENT.availabilityCheck,
          category: BOOKING_LOG_CATEGORY,
          action: BOOKING_LOG_ACTION.availabilityCheck,
          propertyId,
          chaletMode: effectiveChaletMode(pdata),
          result: "blocked",
          reason,
        });
        return { available: false, reason };
      }
      if (effectiveChaletMode(pdata) !== "daily") {
        const reason = "not_daily_chalet" satisfies CheckBookingAvailabilityReason;
        console.warn({
          event: "booking.availability.check",
          legacyEvent: BOOKING_LOG_LEGACY_EVENT.availabilityCheck,
          category: BOOKING_LOG_CATEGORY,
          action: BOOKING_LOG_ACTION.availabilityCheck,
          propertyId,
          chaletMode: effectiveChaletMode(pdata),
          result: "blocked",
          reason,
        });
        return { available: false, reason };
      }

      const available = await isDateRangeAvailable(propertyId, start, end);
      if (!available) {
        const reason = "overlap" satisfies CheckBookingAvailabilityReason;
        console.warn({
          event: "booking.availability.check",
          legacyEvent: BOOKING_LOG_LEGACY_EVENT.availabilityCheck,
          category: BOOKING_LOG_CATEGORY,
          action: BOOKING_LOG_ACTION.availabilityCheck,
          propertyId,
          result: "blocked",
          reason,
        });
        return { available: false, reason };
      }
      console.info({
        event: "booking.availability.check",
        legacyEvent: BOOKING_LOG_LEGACY_EVENT.availabilityCheck,
        category: BOOKING_LOG_CATEGORY,
        action: BOOKING_LOG_ACTION.availabilityCheck,
        propertyId,
        chaletMode: effectiveChaletMode(pdata),
        startDate: start?.toMillis?.(),
        endDate: end?.toMillis?.(),
        result: "available",
        reason: null,
      });
      return { available: true };
    } catch (err: unknown) {
      logBookingError(err, propertyId);
      throw err;
    }
  }
);

/**
 * Secure create: overlap checked inside transaction against confirmed bookings only.
 */
export const createBooking = onCall(
  { region: "us-central1" },
  async (request) => {
    const clientId = requireUid(request);

    const propertyId =
      typeof request.data?.propertyId === "string" ? request.data.propertyId.trim() : "";
    const start = parseRequestTimestamp(request.data?.startDate);
    const end = parseRequestTimestamp(request.data?.endDate);

    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId is required");
    }
    if (!start || !end) {
      throw new HttpsError("invalid-argument", "startDate and endDate are required");
    }
    if (start.toMillis() === end.toMillis()) {
      throw new HttpsError("invalid-argument", "Invalid booking duration");
    }
    if (start.toMillis() > end.toMillis()) {
      throw new HttpsError("invalid-argument", "startDate must be before endDate");
    }

    const propRef = db.collection("properties").doc(propertyId);
    const propSnap = await propRef.get();
    const pdata = propSnap.data();
    const bookable = chaletPropertyBookable(pdata);
    if (!bookable.ok) {
      if (pdata?.listingCategory === "chalet" && effectiveChaletMode(pdata) !== "daily") {
        throw new HttpsError(
          "failed-precondition",
          "Booking not allowed for this property type"
        );
      }
      throw new HttpsError(
        "failed-precondition",
        "Property is not available for chalet booking"
      );
    }
    if (bookable.ownerId === clientId) {
      throw new HttpsError("invalid-argument", "You cannot book your own listing");
    }

    if (!bookable.pricePerNight || Number(bookable.pricePerNight) <= 0) {
      throw new HttpsError("failed-precondition", "Invalid price per night");
    }

    const daysCount = computeDaysCount(start, end);
    const totalPrice =
      Math.round(Number(bookable.pricePerNight) * daysCount * 1000) / 1000;

    const bookingRef = db.collection("bookings").doc();
    const payload = {
      propertyId,
      ownerId: bookable.ownerId,
      clientId,
      startDate: start,
      endDate: end,
      status: "pending" as BookingStatus,
      pricePerNight: Number(bookable.pricePerNight) || 0,
      currency: "KWD",
      totalPrice,
      daysCount,
      createdAt: FieldValue.serverTimestamp(),
      bookingVersion: 1,
    };

    try {
      await db.runTransaction(async (tx) => {
        const q = db
          .collection("bookings")
          .where("propertyId", "==", propertyId)
          .where("status", "==", "confirmed");
        const confirmed = await tx.get(q);
        for (const doc of confirmed.docs) {
          const d = doc.data();
          const bs = d.startDate as admin.firestore.Timestamp | undefined;
          const be = d.endDate as admin.firestore.Timestamp | undefined;
          if (!bs || !be) continue;
          if (rangesOverlap(start, end, bs, be)) {
            throw new HttpsError(
              "already-exists",
              "These dates overlap an existing confirmed booking"
            );
          }
        }
        tx.set(bookingRef, payload);
      });
    } catch (err: unknown) {
      if (!(err instanceof HttpsError)) {
        logBookingError(err, propertyId);
      }
      throw err;
    }

    const chaletMode = effectiveChaletMode(pdata);
    console.info({
      event: "booking.create.attempt",
      legacyEvent: BOOKING_LOG_LEGACY_EVENT.bookingAttempt,
      category: BOOKING_LOG_CATEGORY,
      action: BOOKING_LOG_ACTION.createAttempt,
      propertyId,
      userId: request.auth?.uid,
      chaletMode,
      status: "pending" as const,
    });

    const areaLabel = propertyAreaArabicForNotification(pdata);
    void sendNotificationToUser({
      uid: bookable.ownerId,
      title: "حجز جديد",
      body: `📩 حجز جديد على شاليهك في ${areaLabel}`,
      notificationType: "booking",
      data: {
        screen: "booking",
        bookingId: bookingRef.id,
        propertyId,
        bookingAction: "created",
      },
    });

    return { ok: true, bookingId: bookingRef.id };
  }
);

/**
 * Owner or admin only. In one transaction: overlap vs **confirmed** (per product rules)
 * and vs **other pending** on the same property (so two overlapping pendings cannot both confirm).
 */
export const confirmBooking = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = requireUid(request);
    const adminUser = isAdminAuth(request.auth);

    const bookingId =
      typeof request.data?.bookingId === "string" ? request.data.bookingId.trim() : "";
    if (!bookingId) {
      throw new HttpsError("invalid-argument", "bookingId is required");
    }

    const bookingRef = db.collection("bookings").doc(bookingId);

    let confirmLogPropertyId = "";
    let confirmLogChaletMode = "";

    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(bookingRef);
        if (!snap.exists) {
          throw new HttpsError("not-found", "Booking not found");
        }

        const data = snap.data()!;
        if (data.status !== "pending") {
          throw new HttpsError("failed-precondition", "Booking is not pending");
        }

        const ownerId =
          typeof data.ownerId === "string" ? data.ownerId.trim() : "";
        if (!ownerId) {
          throw new HttpsError("failed-precondition", "Booking data is invalid");
        }
        if (ownerId !== uid && !adminUser) {
          throw new HttpsError("permission-denied", "Not authorized to confirm this booking");
        }

        const propertyId =
          typeof data.propertyId === "string" ? data.propertyId.trim() : "";
        const start = data.startDate as admin.firestore.Timestamp | undefined;
        const end = data.endDate as admin.firestore.Timestamp | undefined;
        if (!propertyId || !start || !end) {
          throw new HttpsError("failed-precondition", "Booking data is invalid");
        }
        if (start.toMillis() >= end.toMillis()) {
          throw new HttpsError("failed-precondition", "Booking dates are invalid");
        }

        const propRefBooking = db.collection("properties").doc(propertyId);
        const propSnapBooking = await tx.get(propRefBooking);
        const propDataBooking = propSnapBooking.data();
        if (!propDataBooking || propDataBooking.listingCategory !== "chalet") {
          throw new HttpsError("failed-precondition", "Property is not available for chalet booking");
        }
        if (effectiveChaletMode(propDataBooking) !== "daily") {
          throw new HttpsError(
            "failed-precondition",
            "Booking not allowed for this property type"
          );
        }

        confirmLogPropertyId = propertyId;
        confirmLogChaletMode = effectiveChaletMode(propDataBooking);

        const q = db
          .collection("bookings")
          .where("propertyId", "==", propertyId)
          .where("status", "==", "confirmed");
        const confirmed = await tx.get(q);

        for (const doc of confirmed.docs) {
          if (doc.id === bookingId) continue;
          const d = doc.data();
          const bs = d.startDate as admin.firestore.Timestamp | undefined;
          const be = d.endDate as admin.firestore.Timestamp | undefined;
          if (!bs || !be) continue;
          if (rangesOverlap(start, end, bs, be)) {
            throw new HttpsError("failed-precondition", "Dates already booked");
          }
        }

        // Block confirming if another pending request still holds overlapping dates
        // (only confirmed counts for public availability; this closes the double-confirm race).
        const pq = db
          .collection("bookings")
          .where("propertyId", "==", propertyId)
          .where("status", "==", "pending");
        const otherPending = await tx.get(pq);
        for (const doc of otherPending.docs) {
          if (doc.id === bookingId) continue;
          const d = doc.data();
          const bs = d.startDate as admin.firestore.Timestamp | undefined;
          const be = d.endDate as admin.firestore.Timestamp | undefined;
          if (!bs || !be) continue;
          if (rangesOverlap(start, end, bs, be)) {
            throw new HttpsError("failed-precondition", "Dates already booked");
          }
        }

        if (bookingAlreadyHasConfirmedAt(data)) {
          tx.update(bookingRef, {
            status: "confirmed" as BookingStatus,
          });
        } else {
          tx.update(bookingRef, {
            status: "confirmed" as BookingStatus,
            confirmedAt: FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (err: unknown) {
      if (!(err instanceof HttpsError)) {
        logBookingError(err, confirmLogPropertyId || bookingId);
      }
      throw err;
    }

    if (confirmLogPropertyId.length > 0) {
      const chaletMode = confirmLogChaletMode;
      console.info({
        event: "booking.confirm.attempt",
        legacyEvent: BOOKING_LOG_LEGACY_EVENT.bookingAttempt,
        category: BOOKING_LOG_CATEGORY,
        action: BOOKING_LOG_ACTION.confirmAttempt,
        propertyId: confirmLogPropertyId,
        userId: request.auth?.uid,
        chaletMode,
        status: "confirmed" as const,
      });
    }

    try {
      await createTransactionFromConfirmedBooking(bookingId);
    } catch (finErr: unknown) {
      const fe = finErr instanceof Error ? finErr : null;
      console.error({
        event: "booking.error",
        legacyEvent: BOOKING_LOG_LEGACY_EVENT.bookingError,
        category: BOOKING_LOG_CATEGORY,
        action: BOOKING_LOG_ACTION.error,
        propertyId: confirmLogPropertyId || "",
        error: fe?.message ?? String(finErr),
        stack: fe?.stack,
      });
    }

    const confirmedSnap = await bookingRef.get();
    const cd = confirmedSnap.data();
    const guestUid = typeof cd?.clientId === "string" ? cd.clientId.trim() : "";
    const confirmedPropertyId =
      typeof cd?.propertyId === "string" ? cd.propertyId.trim() : "";
    if (guestUid) {
      void sendNotificationToUser({
        uid: guestUid,
        title: "تم التأكيد",
        body: "✅ تم تأكيد حجزك — نتمنى لك إقامة ممتعة",
        notificationType: "booking",
        data: {
          screen: "booking",
          bookingId,
          propertyId: confirmedPropertyId,
          bookingAction: "confirmed",
        },
      });
    }

    return { ok: true };
  }
);

/**
 * Cancel a pending booking: property owner, the guest who requested it, or admin.
 */
export const rejectBooking = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = requireUid(request);
    const adminUser = isAdminAuth(request.auth);

    const bookingId =
      typeof request.data?.bookingId === "string" ? request.data.bookingId.trim() : "";
    if (!bookingId) {
      throw new HttpsError("invalid-argument", "bookingId is required");
    }

    const bookingRef = db.collection("bookings").doc(bookingId);

    let cancelOwnerId = "";
    let cancelClientId = "";
    let cancelPropertyId = "";

    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(bookingRef);
        if (!snap.exists) {
          throw new HttpsError("not-found", "Booking not found");
        }

        const data = snap.data()!;
        if (data.status !== "pending") {
          throw new HttpsError("failed-precondition", "Booking is not pending");
        }

        const ownerId =
          typeof data.ownerId === "string" ? data.ownerId.trim() : "";
        const clientId =
          typeof data.clientId === "string" ? data.clientId.trim() : "";
        const propertyIdRow =
          typeof data.propertyId === "string" ? data.propertyId.trim() : "";
        const allowed =
          (ownerId && ownerId === uid) ||
          (clientId && clientId === uid) ||
          adminUser;
        if (!allowed) {
          throw new HttpsError("permission-denied", "Not authorized to cancel this booking");
        }

        cancelOwnerId = ownerId;
        cancelClientId = clientId;
        cancelPropertyId = propertyIdRow;

        tx.update(bookingRef, {
          status: "cancelled" as BookingStatus,
        });
      });
    } catch (err: unknown) {
      if (!(err instanceof HttpsError)) {
        logBookingError(err, bookingId);
      }
      throw err;
    }

    const actor = uid;
    const cancelPayload: Record<string, string> = {
      screen: "booking",
      bookingId,
      propertyId: cancelPropertyId,
      bookingAction: "cancelled",
    };
    if (cancelClientId && actor === cancelClientId && cancelOwnerId) {
      void sendNotificationToUser({
        uid: cancelOwnerId,
        title: "إلغاء حجز",
        body: "❌ تم إلغاء أحد الحجوزات على شاليهك",
        notificationType: "booking",
        persistedNotificationType: "cancel",
        data: { ...cancelPayload, cancelledBy: "guest" },
      });
    } else if (cancelClientId && actor !== cancelClientId) {
      void sendNotificationToUser({
        uid: cancelClientId,
        title: "إلغاء حجز",
        body: "❌ تم إلغاء حجزك",
        notificationType: "booking",
        persistedNotificationType: "cancel",
        data: { ...cancelPayload, cancelledBy: "owner_or_admin" },
      });
    }

    return { ok: true };
  }
);
