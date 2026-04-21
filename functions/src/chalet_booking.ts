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
 *   "status": "pending_payment",
 *   "pricePerNight": 80,
 *   "currency": "KWD",
 *   "totalPrice": 240,
 *   "daysCount": 3,
 *   "createdAt": Timestamp (server),
 *   "expiresAt": Timestamp (createdAt + 5m hold until payment),
 *   "confirmedAt": Timestamp (only after confirm — optional on legacy reads),
 *   "bookingVersion": 1 (optional on newer creates)
 * }
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import {
  ensureChaletLedgerForConfirmedBooking,
  COMMISSION_RATE,
} from "./chalet_booking_finance";
import { writeExceptionLog } from "./exceptionLogs";
import { sendNotificationToUser } from "./sendUserNotification";

const db = admin.firestore();

/** Hold length for unpaid `pending_payment` bookings (availability + payment window). */
export const PENDING_PAYMENT_HOLD_MS = 5 * 60 * 1000;

/**
 * Whether a `pending_payment` row still blocks overlapping dates / payment actions.
 * Prefers `expiresAt` when set; otherwise `createdAt + PENDING_PAYMENT_HOLD_MS` (legacy).
 */
export function pendingPaymentStillHolds(
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

export type BookingStatus = "pending_payment" | "confirmed" | "cancelled";

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
  /** Payment window end for `pending_payment`; omit on legacy documents. */
  expiresAt?: admin.firestore.Timestamp;
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

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

/** Matches Firestore rules: boolean true or legacy string "true". */
function isAdminAuth(auth: { token?: Record<string, unknown> } | undefined): boolean {
  if (!auth?.token) return false;
  const a = auth.token.admin;
  return a === true || a === "true";
}

/** Mirrors Firestore rules [propertyPublicDiscovery] for server-side calendar access. */
function propertyPublicDiscoveryServer(data: admin.firestore.DocumentData | undefined): boolean {
  if (!data) return false;
  if (data.approved !== true) return false;
  if ("status" in data && data.status === "pending_upload") return false;
  if (!("hiddenFromPublic" in data) || data.hiddenFromPublic !== false) return false;
  const typeChalet = "type" in data && data.type === "chalet";
  const listChalet = "listingCategory" in data && data.listingCategory === "chalet";
  const listNormal =
    "listingCategory" in data &&
    data.listingCategory === "normal" &&
    data.isActive === true;
  return typeChalet || listChalet || listNormal;
}

/**
 * Who may load booking overlap ranges for the calendar without reading `bookings` from the client:
 * public discoverable listing, property owner, or admin.
 */
function canReadChaletBusyCalendar(
  pdata: admin.firestore.DocumentData | undefined,
  request: { auth?: { uid?: string; token?: Record<string, unknown> } }
): boolean {
  if (!pdata) return false;
  if (pdata.listingCategory !== "chalet") return false;
  if (effectiveChaletMode(pdata) !== "daily") return false;
  if (propertyPublicDiscoveryServer(pdata)) return true;
  const uid = request.auth?.uid;
  if (uid && typeof pdata.ownerId === "string" && pdata.ownerId.trim() === uid) {
    return true;
  }
  if (isAdminAuth(request.auth)) return true;
  return false;
}

/** Booking rows that block the calendar (confirmed + active pending_payment holds). No PII in response. */
async function loadBookingOverlapRangesForProperty(
  propertyId: string,
  nowMs: number
): Promise<Array<{ start: admin.firestore.Timestamp; end: admin.firestore.Timestamp }>> {
  const trimmed = propertyId.trim();
  if (!trimmed) return [];

  const snap = await db
    .collection("bookings")
    .where("propertyId", "==", trimmed)
    .where("status", "in", ["pending_payment", "confirmed"])
    .get();

  const out: Array<{ start: admin.firestore.Timestamp; end: admin.firestore.Timestamp }> = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    const st = typeof d.status === "string" ? d.status.trim() : "";
    if (st === "pending_payment" && !pendingPaymentStillHolds(d, nowMs)) {
      continue;
    }
    const bs = d.startDate as admin.firestore.Timestamp | undefined;
    const be = d.endDate as admin.firestore.Timestamp | undefined;
    if (!bs || !be) continue;
    out.push({ start: bs, end: be });
  }
  return out;
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
  /** Higher nightly rate for configured peak weekdays; defaults to [pricePerNight]. */
  weekendPricePerNight: number;
  /** ISO weekdays Mon=1 … Sun=7 (matches Dart [DateTime.weekday]). */
  weekendWeekdays: number[];
} {
  const bad = { ok: false, ownerId: "", pricePerNight: 0, weekendPricePerNight: 0, weekendWeekdays: [4, 5, 6] };
  if (!data) return bad;
  if (data.listingCategory !== "chalet") return bad;
  if (effectiveChaletMode(data) !== "daily") return bad;
  if (data.approved !== true) return bad;
  // Public marketplace: must match app + rules (`hiddenFromPublic` must be boolean false).
  if (data.hiddenFromPublic !== false) return bad;
  const owner = data.ownerId;
  if (typeof owner !== "string" || !owner.trim()) return bad;
  const price =
    typeof data.price === "number" ? data.price : Number(data.price);
  if (!Number.isFinite(price) || price <= 0) return bad;

  let weekendPrice = price;
  const wpRaw = data.chaletWeekendPricePerNight ?? data.weekendPricePerNight;
  const wp = typeof wpRaw === "number" ? wpRaw : Number(wpRaw);
  if (Number.isFinite(wp) && wp > price) {
    weekendPrice = wp;
  }

  let weekendWeekdays = [4, 5, 6];
  const rawWd = data.chaletWeekendWeekdays ?? data.weekendWeekdays;
  if (Array.isArray(rawWd)) {
    const mapped = rawWd
      .map((x) => (typeof x === "number" ? x : Number(x)))
      .filter((n) => Number.isInteger(n) && n >= 1 && n <= 7);
    if (mapped.length > 0) weekendWeekdays = mapped;
  }

  return {
    ok: true,
    ownerId: owner.trim(),
    pricePerNight: price,
    weekendPricePerNight: weekendPrice,
    weekendWeekdays,
  };
}

/**
 * Guest payment confirmation: listing must still be approved and publicly bookable.
 * Mirrors app [listingDataIsPubliclyDiscoverable] for the critical `approved` + `hiddenFromPublic` slice.
 */
function assertPropertyPublicForGuestBookingPayment(
  pdata: admin.firestore.DocumentData | undefined
): void {
  if (!pdata) {
    throw new HttpsError("failed-precondition", "Property is not available for booking");
  }
  if (pdata.approved !== true) {
    throw new HttpsError("failed-precondition", "Property is not available for booking");
  }
  if (pdata.hiddenFromPublic !== false) {
    throw new HttpsError("failed-precondition", "Property is not available for booking");
  }
}

/** Dart [DateTime.weekday]: Mon=1 … Sun=7 from UTC instant. */
function dartWeekdayFromUtcMs(ms: number): number {
  const w = new Date(ms).getUTCDay();
  return w === 0 ? 7 : w;
}

/**
 * Sum nightly rates for [start, end) using peak weekdays (aligned with app calendar nights).
 */
function sumChaletStayKwd(args: {
  start: admin.firestore.Timestamp;
  end: admin.firestore.Timestamp;
  weekdayPrice: number;
  peakPrice: number;
  peakDartWeekdays: number[];
}): { total: number; nights: number } {
  const { start, end, weekdayPrice, peakPrice, peakDartWeekdays } = args;
  const nights = computeDaysCount(start, end);
  const peakSet = new Set(
    peakDartWeekdays.filter((n) => Number.isInteger(n) && n >= 1 && n <= 7)
  );
  const usePeak = Number.isFinite(peakPrice) && peakPrice > weekdayPrice;
  const startMs = start.toMillis();
  const msPerDay = 86400000;
  let total = 0;
  for (let i = 0; i < nights; i++) {
    const instant = startMs + i * msPerDay;
    const dow = dartWeekdayFromUtcMs(instant);
    const rate = usePeak && peakSet.has(dow) ? peakPrice : weekdayPrice;
    total += rate;
  }
  return { total: Math.round(total * 1000) / 1000, nights };
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
    .where("status", "in", ["pending_payment", "confirmed"])
    .get();

  const nowMs = Date.now();
  for (const doc of snap.docs) {
    const d = doc.data();
    const st = typeof d.status === "string" ? d.status.trim() : "";
    if (st === "pending_payment" && !pendingPaymentStillHolds(d, nowMs)) {
      continue;
    }
    const bs = d.startDate as admin.firestore.Timestamp | undefined;
    const be = d.endDate as admin.firestore.Timestamp | undefined;
    if (!bs || !be) continue;
    if (rangesOverlap(start, end, bs, be)) return false;
  }
  // Also block external/manual ranges.
  const blocks = await db
    .collection("blocked_dates")
    .where("propertyId", "==", trimmed)
    .where("startDate", "<=", end)
    .get();
  for (const doc of blocks.docs) {
    const d = doc.data();
    const bs = d.startDate as admin.firestore.Timestamp | undefined;
    const be = d.endDate as admin.firestore.Timestamp | undefined;
    if (!bs || !be) continue;
    if (rangesOverlap(start, end, bs, be)) return false;
  }
  return true;
}

/**
 * Defense-in-depth overlap re-check used when a booking is being transitioned
 * to `confirmed`. Must be called inside a Firestore transaction BEFORE any
 * writes. Re-verifies that no other active booking (`confirmed` or valid
 * `pending_payment` hold) and no `blocked_dates` range overlaps the booking's
 * [start, end) on the same property.
 *
 * This is a defense-in-depth layer: `createBooking` already enforces the
 * same invariant transactionally, but we re-check at confirmation time to
 * survive:
 *   - Manual admin/owner writes to `blocked_dates` during a payment session.
 *   - Any future out-of-band writer to `bookings` / `blocked_dates`.
 *   - Clock skew on `expiresAt` around the hold boundary.
 *
 * Throws `HttpsError("failed-precondition", "DATES_NOT_AVAILABLE")` on any
 * overlap so payment confirmation is aborted before the status flips.
 */
async function assertNoFinalizationOverlapInTx(
  tx: admin.firestore.Transaction,
  propertyId: string,
  start: admin.firestore.Timestamp,
  end: admin.firestore.Timestamp,
  excludeBookingId: string
): Promise<void> {
  const pid = propertyId.trim();
  if (!pid) {
    throw new HttpsError("failed-precondition", "Property is not available for booking");
  }
  if (start.toMillis() >= end.toMillis()) {
    throw new HttpsError("failed-precondition", "Booking dates are invalid");
  }

  const bookingsQ = db
    .collection("bookings")
    .where("propertyId", "==", pid)
    .where("status", "in", ["pending_payment", "confirmed"]);
  const existing = await tx.get(bookingsQ);
  const nowMs = Date.now();
  for (const doc of existing.docs) {
    if (doc.id === excludeBookingId) continue;
    const d = doc.data();
    const st = typeof d.status === "string" ? d.status.trim() : "";
    if (st === "pending_payment" && !pendingPaymentStillHolds(d, nowMs)) continue;
    const bs = d.startDate as admin.firestore.Timestamp | undefined;
    const be = d.endDate as admin.firestore.Timestamp | undefined;
    if (!bs || !be) continue;
    if (rangesOverlap(start, end, bs, be)) {
      throw new HttpsError("failed-precondition", "DATES_NOT_AVAILABLE");
    }
  }

  const blocksQ = db
    .collection("blocked_dates")
    .where("propertyId", "==", pid)
    .where("startDate", "<=", end);
  const blocks = await tx.get(blocksQ);
  for (const doc of blocks.docs) {
    const d = doc.data();
    const bs = d.startDate as admin.firestore.Timestamp | undefined;
    const be = d.endDate as admin.firestore.Timestamp | undefined;
    if (!bs || !be) continue;
    if (rangesOverlap(start, end, bs, be)) {
      throw new HttpsError("failed-precondition", "DATES_NOT_AVAILABLE");
    }
  }
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
 * Booking overlap intervals for calendar UI (milliseconds only — no guest/owner PII).
 * Clients should still merge `blocked_dates` from Firestore. Callable may be unauthenticated
 * when the listing is publicly discoverable; owners/admins may load non-public listings.
 */
export const getChaletBusyDateRanges = onCall(
  { region: "us-central1" },
  async (request) => {
    const propertyId =
      typeof request.data?.propertyId === "string" ? request.data.propertyId.trim() : "";
    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId is required");
    }

    const propSnap = await db.collection("properties").doc(propertyId).get();
    const pdata = propSnap.data();
    if (!canReadChaletBusyCalendar(pdata, request)) {
      throw new HttpsError("permission-denied", "Cannot load calendar for this property");
    }

    const ranges = await loadBookingOverlapRangesForProperty(propertyId, Date.now());
    return {
      ranges: ranges.map((r) => ({
        startMs: r.start.toMillis(),
        endMs: r.end.toMillis(),
      })),
    };
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

    const priced = sumChaletStayKwd({
      start,
      end,
      weekdayPrice: bookable.pricePerNight,
      peakPrice: bookable.weekendPricePerNight,
      peakDartWeekdays: bookable.weekendWeekdays,
    });
    const daysCount = priced.nights;
    const totalPrice = priced.total;

    const bookingRef = db.collection("bookings").doc();
    const holdUntil = admin.firestore.Timestamp.fromMillis(Date.now() + PENDING_PAYMENT_HOLD_MS);
    const payload = {
      propertyId,
      ownerId: bookable.ownerId,
      clientId,
      startDate: start,
      endDate: end,
      // TODO: After payment integration, update status to "confirmed" only after payment success
      status: "pending_payment" as BookingStatus,
      pricePerNight: Number(bookable.pricePerNight) || 0,
      currency: "KWD",
      totalPrice,
      daysCount,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: holdUntil,
      bookingVersion: 1,
    };

    try {
      await db.runTransaction(async (tx) => {
        // Atomic overlap check against:
        // - bookings (status != cancelled)
        // - blocked_dates (external/manual blocks)
        //
        // Overlap logic:
        // (startDate <= existingEndDate) && (endDate >= existingStartDate)
        const bookingsQ = db
          .collection("bookings")
          .where("propertyId", "==", propertyId)
          .where("status", "in", ["pending_payment", "confirmed"]);
        const existingBookings = await tx.get(bookingsQ);
        const nowMsTx = Date.now();
        for (const doc of existingBookings.docs) {
          const d = doc.data();
          const st = typeof d.status === "string" ? d.status.trim() : "";
          if (st === "pending_payment" && !pendingPaymentStillHolds(d, nowMsTx)) {
            continue;
          }
          const bs = d.startDate as admin.firestore.Timestamp | undefined;
          const be = d.endDate as admin.firestore.Timestamp | undefined;
          if (!bs || !be) continue;
          if (rangesOverlap(start, end, bs, be)) {
            throw new HttpsError("failed-precondition", "DATES_NOT_AVAILABLE");
          }
        }

        const blocksQ = db
          .collection("blocked_dates")
          .where("propertyId", "==", propertyId)
          .where("startDate", "<=", end);
        const existingBlocks = await tx.get(blocksQ);
        for (const doc of existingBlocks.docs) {
          const d = doc.data();
          const bs = d.startDate as admin.firestore.Timestamp | undefined;
          const be = d.endDate as admin.firestore.Timestamp | undefined;
          if (!bs || !be) continue;
          if (rangesOverlap(start, end, bs, be)) {
            throw new HttpsError("failed-precondition", "DATES_NOT_AVAILABLE");
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
      status: "pending_payment" as const,
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

    return {
      ok: true,
      bookingId: bookingRef.id,
      totalPrice,
      daysCount,
      pricePerNight: Number(bookable.pricePerNight) || 0,
    };
  }
);

/** Log label for [finalizeBookingAfterPayment] (fake | myfatoorah | simulate). */
export type FinalizeBookingConfirmationSourceLog =
  | "fake"
  | "myfatoorah"
  | "simulate";

export type FinalizeBookingAfterPaymentMode =
  | { kind: "fake"; uid: string; isAdmin: boolean }
  | {
      kind: "myfatoorah";
      uid: string;
      paymentId: string;
      paymentGatewayStatus: string;
    }
  | { kind: "owner_confirm"; uid: string; isAdmin: boolean }
  | { kind: "guest_simulate"; uid: string; isAdmin: boolean };

/** Platform/owner ledger write outcome, echoed back onto the booking doc. */
export interface FinancialPostingResult {
  adminLedgerId: string;
  ownerLedgerId: string;
  commissionRate: number;
  commissionAmount: number;
  ownerNet: number;
  grossAmount: number;
}

/**
 * INTERNAL: single source of truth for platform + owner ledger writes during
 * booking finalization. Every confirmation path (fake, MyFatoorah verify,
 * guest simulate) MUST call this so admin_metrics roll-up
 * ([onAdminLedgerCreatedFinanceMetrics]) fires and owner payout is queued.
 *
 * Transaction ordering contract: caller MUST have issued every `tx.get` it
 * needs BEFORE calling this helper (Firestore forbids reads after writes).
 * The legacy `transactions/{bookingId}` snapshot must be read by the caller
 * and passed in via [legacyTxSnap] + [legacyTxRef].
 *
 * Idempotency: when [existingAdminLedgerId] / [existingOwnerLedgerId] are
 * provided (e.g. a fake-pay retry resuming a partially-applied state), the
 * same doc IDs are reused instead of allocating fresh ones.
 */
function postFinancialRecordsInTx(args: {
  tx: admin.firestore.Transaction;
  bookingId: string;
  propertyId: string;
  ownerId: string;
  totalPrice: number;
  paymentId: string;
  legacyTxRef: admin.firestore.DocumentReference;
  legacyTxSnap: admin.firestore.DocumentSnapshot;
  existingAdminLedgerId?: string;
  existingOwnerLedgerId?: string;
}): FinancialPostingResult {
  const {
    tx,
    bookingId,
    propertyId,
    ownerId,
    totalPrice,
    paymentId,
    legacyTxRef,
    legacyTxSnap,
    existingAdminLedgerId,
    existingOwnerLedgerId,
  } = args;

  const gross =
    Number.isFinite(totalPrice) && totalPrice > 0 ? totalPrice : 0;
  const commissionRate = COMMISSION_RATE;
  const commissionAmount = round3(gross * commissionRate);
  const ownerNet = round3(gross - commissionAmount);

  const adminLedgerRef = existingAdminLedgerId
    ? db.collection("admin_ledger").doc(existingAdminLedgerId)
    : db.collection("admin_ledger").doc();
  const ownerLedgerRef = existingOwnerLedgerId
    ? db.collection("owner_ledger").doc(existingOwnerLedgerId)
    : db.collection("owner_ledger").doc();

  tx.set(
    adminLedgerRef,
    {
      type: "booking_commission",
      bookingId,
      propertyId,
      ownerId,
      amount: commissionAmount,
      currency: "KWD",
      source: "chalet_booking",
      paymentReference: paymentId,
      createdAt: FieldValue.serverTimestamp(),
    },
    { merge: false }
  );

  tx.set(
    ownerLedgerRef,
    {
      ownerId,
      bookingId,
      propertyId,
      grossAmount: gross,
      commission: commissionAmount,
      netAmount: ownerNet,
      currency: "KWD",
      status: "pending_payout",
      createdAt: FieldValue.serverTimestamp(),
    },
    { merge: false }
  );

  if (legacyTxSnap.exists) {
    tx.update(legacyTxRef, {
      paymentReference: paymentId,
      commissionRate,
      commissionAmount,
      netAmount: ownerNet,
      platformRevenue: commissionAmount,
      ownerPayoutAmount: ownerNet,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  return {
    adminLedgerId: adminLedgerRef.id,
    ownerLedgerId: ownerLedgerRef.id,
    commissionRate,
    commissionAmount,
    ownerNet,
    grossAmount: gross,
  };
}

/**
 * INTERNAL: single writer for `status: "confirmed"` on `bookings/{bookingId}`.
 * All confirmation paths (guest simulate, fake pay, MyFatoorah verify)
 * must route through this function so `status: "confirmed"` is not set elsewhere.
 *
 * Financial invariant: every branch calls [postFinancialRecordsInTx] inside
 * the same transaction before updating the booking, so admin_ledger +
 * owner_ledger are always written and admin_metrics rollup is always
 * triggered via [onAdminLedgerCreatedFinanceMetrics].
 */
export async function finalizeBookingAfterPayment(
  bookingId: string,
  mode: FinalizeBookingAfterPaymentMode
): Promise<{ paymentId?: string }> {
  const bid = bookingId.trim();
  if (!bid) {
    throw new HttpsError("invalid-argument", "bookingId is required");
  }

  if (mode.kind === "owner_confirm") {
    console.warn("OWNER_CONFIRM_DISABLED", { bookingId: bid });
    throw new HttpsError("permission-denied", "Manual confirmation is disabled");
  }

  const sourceLog: FinalizeBookingConfirmationSourceLog =
    mode.kind === "fake"
      ? "fake"
      : mode.kind === "myfatoorah"
        ? "myfatoorah"
        : "simulate";

  console.info(
    JSON.stringify({
      tag: "booking.finalize",
      CONFIRMATION_SOURCE: sourceLog,
      bookingId: bid,
    })
  );

  const bookingRef = db.collection("bookings").doc(bid);
  let transitionedToConfirmed = false;
  let outPaymentId: string | undefined;

  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(bookingRef);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Booking not found");
      }
      const data = snap.data()!;

      if (mode.kind === "myfatoorah") {
        const st = typeof data.status === "string" ? data.status.trim() : "";
        if (st === "confirmed") {
          return;
        }
        if (st !== "pending_payment") {
          throw new HttpsError("failed-precondition", "Booking is not pending_payment");
        }
        if (!pendingPaymentStillHolds(data, Date.now())) {
          throw new HttpsError("failed-precondition", "BOOKING_PAYMENT_WINDOW_EXPIRED");
        }
        const clientId2 = typeof data.clientId === "string" ? data.clientId.trim() : "";
        if (!clientId2 || clientId2 !== mode.uid) {
          throw new HttpsError("permission-denied", "Not your booking");
        }

        const propertyIdMf =
          typeof data.propertyId === "string" ? data.propertyId.trim() : "";
        if (!propertyIdMf) {
          throw new HttpsError("failed-precondition", "Property is not available for booking");
        }
        const propSnapMf = await tx.get(db.collection("properties").doc(propertyIdMf));
        assertPropertyPublicForGuestBookingPayment(propSnapMf.data());

        const startMf = data.startDate as admin.firestore.Timestamp | undefined;
        const endMf = data.endDate as admin.firestore.Timestamp | undefined;
        if (!startMf || !endMf) {
          throw new HttpsError("failed-precondition", "Booking data is invalid");
        }
        await assertNoFinalizationOverlapInTx(tx, propertyIdMf, startMf, endMf, bid);

        const ownerIdMf =
          typeof data.ownerId === "string" ? data.ownerId.trim() : "";
        if (!ownerIdMf) {
          throw new HttpsError("failed-precondition", "Booking data is invalid");
        }
        const totalPriceMfRaw =
          typeof data.totalPrice === "number"
            ? data.totalPrice
            : Number(data.totalPrice);
        const totalPriceMf = Number.isFinite(totalPriceMfRaw)
          ? totalPriceMfRaw
          : 0;
        const existingAdminLedgerIdMf =
          typeof data.adminLedgerId === "string"
            ? data.adminLedgerId.trim()
            : "";
        const existingOwnerLedgerIdMf =
          typeof data.ownerLedgerId === "string"
            ? data.ownerLedgerId.trim()
            : "";

        // All reads before writes (Firestore tx rule).
        const legacyTxRefMf = db.collection("transactions").doc(bid);
        const legacyTxSnapMf = await tx.get(legacyTxRefMf);

        const postedMf = postFinancialRecordsInTx({
          tx,
          bookingId: bid,
          propertyId: propertyIdMf,
          ownerId: ownerIdMf,
          totalPrice: totalPriceMf,
          paymentId: mode.paymentId,
          legacyTxRef: legacyTxRefMf,
          legacyTxSnap: legacyTxSnapMf,
          existingAdminLedgerId: existingAdminLedgerIdMf || undefined,
          existingOwnerLedgerId: existingOwnerLedgerIdMf || undefined,
        });

        outPaymentId = mode.paymentId;

        tx.update(bookingRef, {
          status: "confirmed" as BookingStatus,
          confirmedAt: FieldValue.serverTimestamp(),
          paymentProvider: "myfatoorah",
          paymentId: mode.paymentId,
          paymentStatus: "paid",
          paymentVerifiedAt: FieldValue.serverTimestamp(),
          paymentGatewayStatus: mode.paymentGatewayStatus,
          paidAt: FieldValue.serverTimestamp(),
          commissionRate: postedMf.commissionRate,
          commissionAmount: postedMf.commissionAmount,
          ownerNet: postedMf.ownerNet,
          adminLedgerId: postedMf.adminLedgerId,
          ownerLedgerId: postedMf.ownerLedgerId,
          financialLedgerVersion: 1,
          updatedAt: FieldValue.serverTimestamp(),
        });
        transitionedToConfirmed = true;
        return;
      }

      if (mode.kind === "guest_simulate") {
        if (data.status !== "pending_payment") {
          throw new HttpsError("failed-precondition", "Booking is not pending_payment");
        }
        if (!pendingPaymentStillHolds(data, Date.now())) {
          throw new HttpsError("failed-precondition", "BOOKING_PAYMENT_WINDOW_EXPIRED");
        }

        const ownerId =
          typeof data.ownerId === "string" ? data.ownerId.trim() : "";
        const clientId =
          typeof data.clientId === "string" ? data.clientId.trim() : "";
        if (!ownerId || !clientId) {
          throw new HttpsError("failed-precondition", "Booking data is invalid");
        }
        if (!mode.isAdmin && clientId !== mode.uid) {
          throw new HttpsError(
            "permission-denied",
            "Only the guest can simulate payment for this booking"
          );
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
        assertPropertyPublicForGuestBookingPayment(propDataBooking);

        await assertNoFinalizationOverlapInTx(tx, propertyId, start, end, bid);

        const totalPriceSimRaw =
          typeof data.totalPrice === "number"
            ? data.totalPrice
            : Number(data.totalPrice);
        const totalPriceSim = Number.isFinite(totalPriceSimRaw)
          ? totalPriceSimRaw
          : 0;
        const existingAdminLedgerIdSim =
          typeof data.adminLedgerId === "string"
            ? data.adminLedgerId.trim()
            : "";
        const existingOwnerLedgerIdSim =
          typeof data.ownerLedgerId === "string"
            ? data.ownerLedgerId.trim()
            : "";
        const existingPaymentIdSim =
          typeof data.paymentId === "string" ? data.paymentId.trim() : "";

        const legacyTxRefSim = db.collection("transactions").doc(bid);
        const legacyTxSnapSim = await tx.get(legacyTxRefSim);

        const paymentIdSim =
          existingPaymentIdSim ||
          `simulate_${bid}_${Date.now()}_${Math.random()
            .toString(16)
            .slice(2, 10)}`;

        const postedSim = postFinancialRecordsInTx({
          tx,
          bookingId: bid,
          propertyId,
          ownerId,
          totalPrice: totalPriceSim,
          paymentId: paymentIdSim,
          legacyTxRef: legacyTxRefSim,
          legacyTxSnap: legacyTxSnapSim,
          existingAdminLedgerId: existingAdminLedgerIdSim || undefined,
          existingOwnerLedgerId: existingOwnerLedgerIdSim || undefined,
        });

        outPaymentId = paymentIdSim;

        tx.update(bookingRef, {
          status: "confirmed" as BookingStatus,
          paymentProvider: "simulate",
          paymentId: paymentIdSim,
          paymentStatus: "paid",
          paidAt: FieldValue.serverTimestamp(),
          paymentVerifiedAt: FieldValue.serverTimestamp(),
          commissionRate: postedSim.commissionRate,
          commissionAmount: postedSim.commissionAmount,
          ownerNet: postedSim.ownerNet,
          adminLedgerId: postedSim.adminLedgerId,
          ownerLedgerId: postedSim.ownerLedgerId,
          financialLedgerVersion: 1,
          updatedAt: FieldValue.serverTimestamp(),
          ...(bookingAlreadyHasConfirmedAt(data)
            ? {}
            : { confirmedAt: FieldValue.serverTimestamp() }),
        });
        transitionedToConfirmed = true;
        return;
      }

      // mode.kind === "fake"
      const existingPaymentStatus =
        typeof data.paymentStatus === "string" ? data.paymentStatus.trim() : "";
      const existingPaymentId =
        typeof data.paymentId === "string" ? data.paymentId.trim() : "";
      const existingAdminLedgerId =
        typeof data.adminLedgerId === "string" ? data.adminLedgerId.trim() : "";
      const existingOwnerLedgerId =
        typeof data.ownerLedgerId === "string" ? data.ownerLedgerId.trim() : "";

      let resultPaymentId = "";

      if (existingPaymentStatus === "paid" && existingPaymentId) {
        if (existingAdminLedgerId && existingOwnerLedgerId) {
          resultPaymentId = existingPaymentId;
          outPaymentId = resultPaymentId;
          return;
        }
        resultPaymentId = existingPaymentId;
      } else {
        if (data.status !== "pending_payment") {
          throw new HttpsError("failed-precondition", "Booking is not pending_payment");
        }
      }

      if (!pendingPaymentStillHolds(data, Date.now())) {
        throw new HttpsError("failed-precondition", "BOOKING_PAYMENT_WINDOW_EXPIRED");
      }

      const ownerIdFake = typeof data.ownerId === "string" ? data.ownerId.trim() : "";
      const clientIdFake = typeof data.clientId === "string" ? data.clientId.trim() : "";
      if (!ownerIdFake || !clientIdFake) {
        throw new HttpsError("failed-precondition", "Booking data is invalid");
      }
      if (!mode.isAdmin && clientIdFake !== mode.uid) {
        throw new HttpsError("permission-denied", "Only the guest can fake-pay this booking");
      }

      const propertyIdFake = typeof data.propertyId === "string" ? data.propertyId.trim() : "";
      const startFake = data.startDate as admin.firestore.Timestamp | undefined;
      const endFake = data.endDate as admin.firestore.Timestamp | undefined;
      if (!propertyIdFake || !startFake || !endFake) {
        throw new HttpsError("failed-precondition", "Booking data is invalid");
      }
      if (startFake.toMillis() >= endFake.toMillis()) {
        throw new HttpsError("failed-precondition", "Booking dates are invalid");
      }

      const propRefFake = db.collection("properties").doc(propertyIdFake);
      const propSnapFake = await tx.get(propRefFake);
      const propDataFake = propSnapFake.data();
      if (!propDataFake || propDataFake.listingCategory !== "chalet") {
        throw new HttpsError("failed-precondition", "Property is not available for chalet booking");
      }
      if (effectiveChaletMode(propDataFake) !== "daily") {
        throw new HttpsError(
          "failed-precondition",
          "Booking not allowed for this property type"
        );
      }
      assertPropertyPublicForGuestBookingPayment(propDataFake);

      await assertNoFinalizationOverlapInTx(tx, propertyIdFake, startFake, endFake, bid);

      const totalPriceRaw =
        typeof data.totalPrice === "number"
          ? data.totalPrice
          : Number(data.totalPrice);
      const totalPriceFake = Number.isFinite(totalPriceRaw) ? totalPriceRaw : 0;

      const paymentId =
        resultPaymentId ||
        `fake_${bid}_${Date.now()}_${Math.random().toString(16).slice(2, 10)}`;
      resultPaymentId = paymentId;
      outPaymentId = paymentId;

      // Firestore transactions require all reads BEFORE any writes — snapshot
      // the legacy ledger row here so the helper can issue its writes safely.
      const legacyTxRef = db.collection("transactions").doc(bid);
      const legacyTxSnap = await tx.get(legacyTxRef);

      const postedFake = postFinancialRecordsInTx({
        tx,
        bookingId: bid,
        propertyId: propertyIdFake,
        ownerId: ownerIdFake,
        totalPrice: totalPriceFake,
        paymentId,
        legacyTxRef,
        legacyTxSnap,
        existingAdminLedgerId: existingAdminLedgerId || undefined,
        existingOwnerLedgerId: existingOwnerLedgerId || undefined,
      });

      tx.update(bookingRef, {
        status: "confirmed" as BookingStatus,
        confirmedAt: FieldValue.serverTimestamp(),
        paymentStatus: "paid",
        paymentProvider: "fake",
        paymentId: paymentId,
        paidAt: FieldValue.serverTimestamp(),
        commissionRate: postedFake.commissionRate,
        commissionAmount: postedFake.commissionAmount,
        ownerNet: postedFake.ownerNet,
        adminLedgerId: postedFake.adminLedgerId,
        ownerLedgerId: postedFake.ownerLedgerId,
        financialLedgerVersion: 1,
      });
      transitionedToConfirmed = true;
    });
  } catch (err: unknown) {
    if (!(err instanceof HttpsError)) {
      logBookingError(err, bid);
    }
    throw err;
  }

  await ensureChaletLedgerForConfirmedBooking(bid);

  if (transitionedToConfirmed) {
    const confirmedSnap = await bookingRef.get();
    const cd = confirmedSnap.data();
    const guestUid = typeof cd?.clientId === "string" ? cd.clientId.trim() : "";
    const confirmedPropertyId =
      typeof cd?.propertyId === "string" ? cd.propertyId.trim() : "";
    if (guestUid) {
      console.info(
        JSON.stringify({
          tag: "NOTIFICATION_SENT_TO_CLIENT",
          bookingId: bid,
          clientId: guestUid,
          CONFIRMATION_SOURCE: sourceLog,
        })
      );
      void sendNotificationToUser({
        uid: guestUid,
        title: "تم تأكيد الحجز",
        body: "تم تأكيد حجزك بنجاح 🎉",
        notificationType: "booking",
        data: {
          screen: "booking",
          bookingId: bid,
          propertyId: confirmedPropertyId,
          bookingAction: "confirmed",
        },
      });
    }

    const propertyIdLog = confirmedPropertyId;
    const propSnapLog = propertyIdLog
      ? await db.collection("properties").doc(propertyIdLog).get()
      : null;
    const chaletModeLog = effectiveChaletMode(propSnapLog?.data());

    if (sourceLog === "simulate") {
      console.info({
        event: "booking.simulate_fake_payment.confirm",
        category: BOOKING_LOG_CATEGORY,
        action: BOOKING_LOG_ACTION.confirmAttempt,
        propertyId: propertyIdLog,
        userId: mode.uid,
        chaletMode: chaletModeLog,
        status: "confirmed" as const,
      });
    } else if (sourceLog === "fake") {
      console.info({
        event: "booking.fake_payment.confirm",
        category: BOOKING_LOG_CATEGORY,
        action: BOOKING_LOG_ACTION.confirmAttempt,
        propertyId: propertyIdLog,
        userId: mode.uid,
        chaletMode: chaletModeLog,
        status: "confirmed" as const,
      });
    }
  }

  return outPaymentId ? { paymentId: outPaymentId } : {};
}

/**
 * @deprecated DISABLED — manual booking confirmation is not allowed.
 *
 * Bookings can ONLY transition to `confirmed` via a payment path that runs
 * through [finalizeBookingAfterPayment], which writes the financial ledgers
 * atomically. Those paths are:
 *   - `fakePayChaletBooking` (dev/QA, gated by `ALLOW_CHALET_FAKE_PAYMENT`)
 *   - `simulateChaletBookingPayment` (dev/QA, same gate)
 *   - `verifyBookingMyFatoorahPayment` (real gateway)
 *
 * This callable exists only to return a clear `permission-denied` error to any
 * legacy client still invoking it. It will be removed once all clients have
 * been verified to no longer reference the `confirmBooking` name. Do NOT add
 * logic here — every caller must migrate to one of the payment paths above.
 */
export const confirmBooking = onCall(
  { region: "us-central1" },
  async (request) => {
    requireUid(request);

    const bookingId =
      typeof request.data?.bookingId === "string" ? request.data.bookingId.trim() : "";
    if (!bookingId) {
      throw new HttpsError("invalid-argument", "bookingId is required");
    }

    console.warn(
      JSON.stringify({
        tag: "confirmBooking.deprecated.invoked",
        bookingId,
        uid: request.auth?.uid ?? null,
        hint:
          "Use fakePayChaletBooking / simulateChaletBookingPayment / verifyBookingMyFatoorahPayment",
      })
    );
    throw new HttpsError(
      "permission-denied",
      "Manual confirmation is disabled. Use a payment path (fakePayChaletBooking / verifyBookingMyFatoorahPayment)."
    );
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
        if (data.status !== "pending_payment") {
          throw new HttpsError("failed-precondition", "Booking is not pending_payment");
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


/**
 * DEV / QA only: confirm a `pending_payment` booking as if payment succeeded.
 * Disabled unless `ALLOW_CHALET_FAKE_PAYMENT=true` on the Functions runtime.
 * Only the guest ([clientId]) or an admin may call this.
 */
export const simulateChaletBookingPayment = onCall(
  { region: "us-central1" },
  async (request) => {
    if (process.env.ALLOW_CHALET_FAKE_PAYMENT !== "true") {
      throw new HttpsError(
        "failed-precondition",
        "Fake booking payment is disabled (set ALLOW_CHALET_FAKE_PAYMENT=true on Functions)"
      );
    }

    const uid = requireUid(request);
    const adminUser = isAdminAuth(request.auth);

    const bookingId =
      typeof request.data?.bookingId === "string" ? request.data.bookingId.trim() : "";
    if (!bookingId) {
      throw new HttpsError("invalid-argument", "bookingId is required");
    }

    try {
      await finalizeBookingAfterPayment(bookingId, {
        kind: "guest_simulate",
        uid,
        isAdmin: adminUser,
      });
    } catch (err: unknown) {
      if (!(err instanceof HttpsError)) {
        logBookingError(err, bookingId);
      }
      throw err;
    }

    return { ok: true, status: "confirmed" as const };
  }
);

/**
 * DEV / QA only: create a fake "paid" record for an existing `pending_payment` booking.
 *
 * This mirrors the real gateway flow shape:
 * - booking status becomes `confirmed`
 * - booking gains `paymentStatus: "paid"` + `paymentId` (fake)
 * - ledger row is ensured in `transactions/{bookingId}`
 *
 * Disabled unless `ALLOW_CHALET_FAKE_PAYMENT=true` on the Functions runtime.
 * Only the guest ([clientId]) or an admin may call this.
 */
export const fakePayChaletBooking = onCall(
  { region: "us-central1" },
  async (request) => {
    if (process.env.ALLOW_CHALET_FAKE_PAYMENT !== "true") {
      throw new HttpsError(
        "failed-precondition",
        "Fake booking payment is disabled (set ALLOW_CHALET_FAKE_PAYMENT=true on Functions)"
      );
    }

    const uid = requireUid(request);
    const adminUser = isAdminAuth(request.auth);

    const bookingId =
      typeof request.data?.bookingId === "string" ? request.data.bookingId.trim() : "";
    if (!bookingId) {
      throw new HttpsError("invalid-argument", "bookingId is required");
    }

    try {
      const { paymentId } = await finalizeBookingAfterPayment(bookingId, {
        kind: "fake",
        uid,
        isAdmin: adminUser,
      });
      return { ok: true, bookingId, paymentId: paymentId ?? "" };
    } catch (err: unknown) {
      if (!(err instanceof HttpsError)) {
        void writeExceptionLog({
          type: "ledger_error",
          relatedId: bookingId,
          message: err instanceof Error ? err.message : String(err),
          severity: "high",
        });
      }
      throw err;
    }
  }
);
