/**
 * Chalet confirmed-booking financial ledger: `transactions/{bookingId}` only (no edits to `bookings`).
 * Document ID === bookingId for idempotency under concurrency. Commission frozen at create (COMMISSION_RATE).
 *
 * Owner display fields are snapshotted from `users/{ownerId}` at ledger create (recommended shape:
 * `name`, `phone`, optional `role`). Missing fields become empty strings; ledger create still succeeds.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { writeExceptionLog } from "./exceptionLogs";
import { formatKwdForNotification, sendNotificationToUser } from "./sendUserNotification";

const db = admin.firestore();

/**
 * Centralized platform commission on gross booking total (frozen on ledger write).
 *
 * Single source of truth for commission across every confirmation path
 * (fake, MyFatoorah, guest simulate) and both ledgers (`admin_ledger`,
 * `owner_ledger`) plus the canonical `transactions/{bookingId}` row.
 */
export const COMMISSION_RATE = 0.15;

/**
 * Guest refund (gross) before checkIn snapshot, admin-only execution on ledger.
 * ≥7 calendar days before start → full gross refund; ≥2 days → 50%; else not eligible.
 */
const REFUND_FULL_MIN_DAYS_BEFORE_START = 7;
const REFUND_PARTIAL_MIN_DAYS_BEFORE_START = 2;
const PARTIAL_REFUND_FRACTION = 0.5;

/** Financial row lifecycle (not payoutStatus). */
export type ChaletLedgerStatus = "pending" | "confirmed" | "cancelled" | "refunded";

export type ChaletRefundStatus = "none" | "partial" | "full";

function roundKwd3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

const LEDGER_EPS = 0.001;

function readCoreAmounts(data: admin.firestore.DocumentData): {
  amount: number;
  netAmount: number;
  commissionAmount: number;
  ownerPayoutAmount: number;
} | null {
  const amount = typeof data.amount === "number" ? data.amount : Number(data.amount);
  const netAmount = typeof data.netAmount === "number" ? data.netAmount : Number(data.netAmount);
  const commissionAmount =
    typeof data.commissionAmount === "number"
      ? data.commissionAmount
      : Number(data.commissionAmount);
  const ownerRaw = data.ownerPayoutAmount;
  const ownerPayoutAmount =
    typeof ownerRaw === "number" && Number.isFinite(ownerRaw) ? ownerRaw : netAmount;
  if (!Number.isFinite(amount) || !Number.isFinite(netAmount)) {
    return null;
  }
  return {
    amount,
    netAmount,
    commissionAmount: Number.isFinite(commissionAmount) ? commissionAmount : 0,
    ownerPayoutAmount: Number.isFinite(ownerPayoutAmount) ? ownerPayoutAmount : 0,
  };
}

/** Blocks mutations when ledger row is terminal (paid out or fully closed refund path). */
function assertTransactionMutable(data: admin.firestore.DocumentData): void {
  if (data.isFinalized === true) {
    throw new HttpsError("failed-precondition", "Transaction is finalized");
  }
}

/**
 * PART 1 / 7 / 8 — invalid or mismatched pre-mutation ledger; persists hasIssue when possible.
 */
function flagFinancialAnomalies(
  tx: admin.firestore.Transaction,
  ref: admin.firestore.DocumentReference,
  data: admin.firestore.DocumentData,
  updatedBy: string
): "invalid" | "mismatch" | null {
  const nums = readCoreAmounts(data);
  if (!nums || nums.amount <= 0 || nums.netAmount < 0) {
    tx.update(ref, {
      hasIssue: true,
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy,
    });
    return "invalid";
  }
  if (String(data.refundStatus ?? "none") !== "none") {
    return null;
  }
  if (
    Math.abs(nums.commissionAmount + nums.ownerPayoutAmount - nums.amount) > LEDGER_EPS
  ) {
    tx.update(ref, {
      hasIssue: true,
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy,
    });
    return "mismatch";
  }
  return null;
}

function computeRefundAmountGross(
  gross: number,
  start: admin.firestore.Timestamp,
  now: admin.firestore.Timestamp
): number {
  const msUntil = start.toMillis() - now.toMillis();
  if (msUntil <= 0) {
    throw new HttpsError(
      "failed-precondition",
      "Stay already started or finished; refund not allowed by policy"
    );
  }
  const daysUntil = msUntil / 86400000;
  if (daysUntil >= REFUND_FULL_MIN_DAYS_BEFORE_START) {
    return roundKwd3(gross);
  }
  if (daysUntil >= REFUND_PARTIAL_MIN_DAYS_BEFORE_START) {
    return roundKwd3(gross * PARTIAL_REFUND_FRACTION);
  }
  throw new HttpsError(
    "failed-precondition",
    "Too close to check-in; refund not allowed by policy"
  );
}

function isAdminAuth(auth: { token?: Record<string, unknown> } | undefined): boolean {
  if (!auth?.token) return false;
  const a = auth.token.admin;
  return a === true || a === "true";
}

function requireUid(request: { auth?: { uid?: string } }): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }
  return uid;
}

function pricePerNightFromBooking(b: admin.firestore.DocumentData): number {
  const ppn = b.pricePerNight;
  if (typeof ppn === "number" && Number.isFinite(ppn)) return ppn;
  return Number(ppn) || 0;
}

function daysCountFromBooking(b: admin.firestore.DocumentData): number {
  const d = b.daysCount;
  if (typeof d === "number" && Number.isFinite(d)) return Math.max(0, Math.round(d));
  const n = Number(d);
  return Number.isFinite(n) ? Math.max(0, Math.round(n)) : 0;
}

function propertyTitleSnapshot(p: admin.firestore.DocumentData | undefined): string {
  if (!p) return "";
  const area = String(p.areaAr ?? p.area ?? "").trim();
  const type = String(p.type ?? "").trim();
  const parts = [area, type].filter((x) => x.length > 0);
  if (parts.length > 0) return parts.join(" · ").slice(0, 200);
  const desc = String(p.description ?? "").trim();
  return desc.slice(0, 120);
}

/** Read-friendly owner identity from `users/{uid}` (multiple key aliases for legacy docs). Always trimmed. */
function ownerIdentityFromUserDoc(
  ownerData: admin.firestore.DocumentData | undefined
): { ownerName: string; ownerPhone: string; ownerDisplayName: string } {
  if (!ownerData) {
    return { ownerName: "", ownerPhone: "", ownerDisplayName: "" };
  }
  const rawName = String(
    ownerData.name ?? ownerData.fullName ?? ownerData.displayName ?? ""
  ).trim();
  const rawPhone = String(
    ownerData.phone ?? ownerData.phoneNumber ?? ownerData.ownerPhone ?? ""
  ).trim();
  const ownerName = rawName.slice(0, 200);
  const ownerPhone = rawPhone.slice(0, 80);
  return {
    ownerName,
    ownerPhone,
    ownerDisplayName: ownerName,
  };
}

function buildBookingSnapshot(
  b: admin.firestore.DocumentData,
  propertyData: admin.firestore.DocumentData | undefined,
  pricePerNight: number,
  daysCount: number
): Record<string, unknown> {
  const snap: Record<string, unknown> = {
    pricePerNight,
    daysCount,
    propertyTitle: propertyTitleSnapshot(propertyData),
  };
  if (b.startDate instanceof admin.firestore.Timestamp) {
    snap.startDate = b.startDate;
  }
  if (b.endDate instanceof admin.firestore.Timestamp) {
    snap.endDate = b.endDate;
  }
  return snap;
}

function buildLedgerPayload(
  bid: string,
  b: admin.firestore.DocumentData,
  propertyData: admin.firestore.DocumentData | undefined,
  ownerUserData: admin.firestore.DocumentData | undefined
): Record<string, unknown> | null {
  const propertyId = typeof b.propertyId === "string" ? b.propertyId.trim() : "";
  const ownerId = typeof b.ownerId === "string" ? b.ownerId.trim() : "";
  const clientId = typeof b.clientId === "string" ? b.clientId.trim() : "";
  if (!propertyId || !ownerId || !clientId) return null;

  const amount =
    typeof b.totalPrice === "number" ? b.totalPrice : Number(b.totalPrice);
  if (!Number.isFinite(amount) || amount <= 0) return null;

  const currency =
    typeof b.currency === "string" && b.currency.trim() ? b.currency.trim() : "KWD";

  const commissionRateRaw = typeof b.commissionRate === "number" ? b.commissionRate : Number(b.commissionRate);
  const commissionRate =
    Number.isFinite(commissionRateRaw) && commissionRateRaw > 0 && commissionRateRaw < 1
      ? commissionRateRaw
      : COMMISSION_RATE;
  const commissionAmount = roundKwd3(amount * commissionRate);
  const netAmount = roundKwd3(amount - commissionAmount);

  /** Audit: never missing — booking timestamp or server time at ledger create. */
  const confirmedAt =
    b.confirmedAt instanceof admin.firestore.Timestamp
      ? b.confirmedAt
      : FieldValue.serverTimestamp();

  const bookingVersion =
    typeof b.bookingVersion === "number" && Number.isFinite(b.bookingVersion)
      ? b.bookingVersion
      : 1;

  const pricePerNight = roundKwd3(pricePerNightFromBooking(b));
  const daysCount = daysCountFromBooking(b);
  const bookingSnapshot = buildBookingSnapshot(b, propertyData, pricePerNight, daysCount);

  const { ownerName, ownerPhone, ownerDisplayName } = ownerIdentityFromUserDoc(ownerUserData);

  const ownerSnapshot = {
    uid: ownerId,
    name: ownerName,
    phone: ownerPhone,
  };

  return {
    type: "booking",
    source: "chalet_daily",
    propertyId,
    bookingId: bid,
    ownerId,
    ownerName,
    ownerPhone,
    ownerDisplayName,
    ownerSnapshot,
    clientId,
    amount,
    commissionRate,
    commissionAmount,
    netAmount,
    ownerPayoutAmount: netAmount,
    platformRevenue: commissionAmount,
    /** Manual flow today; set false when payment gateway verifies funds. */
    paymentVerified: true,
    currency,
    status: "confirmed" satisfies ChaletLedgerStatus,
    payoutStatus: "pending",
    refundAmount: 0,
    refundStatus: "none" satisfies ChaletRefundStatus,
    refundReference: "",
    isDeleted: false,
    isFinalized: false,
    hasIssue: false,
    pricePerNight,
    daysCount,
    bookingSnapshot,
    createdBy: "system",
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    confirmedAt,
    bookingVersion,
    payoutMethod: "bank",
    notes: "",
    paymentReference: typeof b.paymentId === "string" ? b.paymentId.trim() : "",
    payoutReference: "",
  };
}

/** Result of [createTransactionFromConfirmedBooking] (idempotent; safe to retry). */
export type CreateChaletLedgerResult =
  | { ok: true; kind: "already_existed" | "created" }
  | { ok: false; reason: string };

/**
 * Idempotent under concurrency: `transactions/{bookingId}` atomically create-if-absent.
 * Document ID === bookingId is the unique key (no duplicate rows for the same booking).
 */
export async function createTransactionFromConfirmedBooking(
  bookingId: string
): Promise<CreateChaletLedgerResult> {
  const bid = bookingId?.trim();
  if (!bid) {
    return { ok: false, reason: "missing_booking_id" };
  }

  try {
    const result = await db.runTransaction(async (tx) => {
      const bookingRef = db.collection("bookings").doc(bid);
      const txRef = db.collection("transactions").doc(bid);

      const [existingTx, bookingSnap] = await Promise.all([
        tx.get(txRef),
        tx.get(bookingRef),
      ]);

      if (existingTx.exists) {
        return { ok: true as const, kind: "already_existed" as const };
      }

      if (!bookingSnap.exists) {
        return { ok: false as const, reason: "booking_not_found" };
      }

      const b = bookingSnap.data()!;
      if (b.status !== "confirmed") {
        return { ok: false as const, reason: "booking_not_confirmed" };
      }

      const propertyId = typeof b.propertyId === "string" ? b.propertyId.trim() : "";
      if (!propertyId) {
        return { ok: false as const, reason: "missing_propertyId" };
      }

      const propertyRef = db.collection("properties").doc(propertyId);
      const propertySnap = await tx.get(propertyRef);
      const propertyData = propertySnap.exists ? propertySnap.data() : undefined;

      const ownerUid = typeof b.ownerId === "string" ? b.ownerId.trim() : "";
      const ownerUserSnap = ownerUid
        ? await tx.get(db.collection("users").doc(ownerUid))
        : null;
      const ownerUserData =
        ownerUserSnap?.exists === true ? ownerUserSnap.data() : undefined;

      const payload = buildLedgerPayload(bid, b, propertyData, ownerUserData);
      if (!payload) {
        return { ok: false as const, reason: "ledger_payload_invalid" };
      }

      tx.set(txRef, payload);
      return { ok: true as const, kind: "created" as const };
    });
    return result;
  } catch (err: unknown) {
    const e = err instanceof Error ? err : null;
    const msg = e?.message ?? String(err);
    console.error({
      event: "finance.transaction.create.failed",
      bookingId: bid,
      error: msg,
      stack: e?.stack,
    });
    return { ok: false, reason: msg };
  }
}

async function markBookingNeedsLedgerReconciliation(
  bookingId: string,
  reason: string
): Promise<void> {
  const bid = bookingId?.trim();
  if (!bid) return;
  const trimmed = reason.trim().slice(0, 500);
  try {
    await db.collection("bookings").doc(bid).update({
      needsLedgerReconciliation: true,
      ledgerReconciliationError: trimmed.length > 0 ? trimmed : "unknown",
      ledgerReconciliationAt: FieldValue.serverTimestamp(),
    });
  } catch (markErr: unknown) {
    const me = markErr instanceof Error ? markErr : null;
    console.error({
      event: "finance.reconciliation.mark_failed",
      bookingId: bid,
      error: me?.message ?? String(markErr),
      stack: me?.stack,
    });
  }
}

/**
 * After any path sets `bookings.status` to `confirmed`, call this so `transactions/{bookingId}` exists.
 * On failure: logs, sets `needsLedgerReconciliation` on the booking for ops backfill.
 */
export async function ensureChaletLedgerForConfirmedBooking(bookingId: string): Promise<void> {
  const result = await createTransactionFromConfirmedBooking(bookingId);
  if (result.ok) {
    if (result.kind === "created") {
      console.info({ event: "finance.transaction.created", bookingId: bookingId.trim() });
    }
    return;
  }
  console.error({
    event: "finance.transaction.ensure_failed",
    bookingId: bookingId.trim(),
    reason: result.reason,
  });
  void writeExceptionLog({
    type: "ledger_error",
    relatedId: bookingId.trim(),
    message: `transactions ledger: ${String(result.reason)}`,
    severity: "high",
  });
  await markBookingNeedsLedgerReconciliation(bookingId, result.reason);
}

/**
 * Admin: after manual bank transfer, mark owner payout complete (transactional, idempotent guard).
 */
export const markChaletBookingTransactionPaid = onCall(
  { region: "us-central1" },
  async (request) => {
    requireUid(request);
    if (!isAdminAuth(request.auth)) {
      throw new HttpsError("permission-denied", "Admin only");
    }

    const txId =
      typeof request.data?.transactionId === "string" ? request.data.transactionId.trim() : "";
    if (!txId) {
      throw new HttpsError("invalid-argument", "transactionId is required");
    }

    const notesRaw = request.data?.notes;
    const notes = typeof notesRaw === "string" ? notesRaw.trim() : "";

    const payoutReferenceRaw = request.data?.payoutReference;
    const payoutReference =
      typeof payoutReferenceRaw === "string" ? payoutReferenceRaw.trim() : "";

    const updatedBy = request.auth?.uid ?? "system";

    let payoutLog:
      | { transactionId: string; ownerId: string; amount: number }
      | undefined;
    let payoutAbort:
      | "corrupt_paid_with_refund"
      | "invalid"
      | "mismatch"
      | undefined;

    await db.runTransaction(async (tx) => {
      const ref = db.collection("transactions").doc(txId);
      const snap = await tx.get(ref);

      if (!snap.exists) {
        throw new HttpsError("not-found", "Transaction not found");
      }

      const data = snap.data()!;
      if (data.type !== "booking" || data.source !== "chalet_daily") {
        throw new HttpsError("failed-precondition", "Invalid transaction");
      }

      const refundSt = String(data.refundStatus ?? "none");

      if (data.payoutStatus === "paid" && refundSt !== "none") {
        tx.update(ref, {
          hasIssue: true,
          updatedAt: FieldValue.serverTimestamp(),
          updatedBy,
        });
        payoutAbort = "corrupt_paid_with_refund";
        return;
      }

      if (data.payoutStatus === "paid") {
        throw new HttpsError("failed-precondition", "Already paid");
      }

      assertTransactionMutable(data);

      if (data.hasIssue === true) {
        throw new HttpsError("failed-precondition", "Transaction has issues");
      }

      const anomaly = flagFinancialAnomalies(tx, ref, data, updatedBy);
      if (anomaly) {
        payoutAbort = anomaly;
        return;
      }

      if (data.payoutStatus !== "pending") {
        throw new HttpsError("failed-precondition", "Payout already processed");
      }

      const nums = readCoreAmounts(data)!;

      const updatePayload: Record<string, unknown> = {
        payoutStatus: "paid",
        paidOutAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        updatedBy,
        payoutReference,
        isFinalized: true,
      };

      if (notes.length > 0) {
        updatePayload.notes = notes;
      }

      tx.update(ref, updatePayload);

      payoutLog = {
        transactionId: txId,
        ownerId: typeof data.ownerId === "string" ? data.ownerId : String(data.ownerId ?? ""),
        amount: nums.ownerPayoutAmount,
      };
    });

    if (payoutAbort === "corrupt_paid_with_refund") {
      throw new HttpsError("failed-precondition", "Cannot refund after payout");
    }
    if (payoutAbort === "invalid") {
      throw new HttpsError("failed-precondition", "Invalid financial values");
    }
    if (payoutAbort === "mismatch") {
      throw new HttpsError("failed-precondition", "Ledger mismatch");
    }

    if (payoutLog === undefined) {
      throw new HttpsError(
        "failed-precondition",
        "Cannot complete payout (ledger issue or inconsistent state)"
      );
    }

    console.info({
      event: "finance.payout.completed",
      transactionId: payoutLog.transactionId,
      ownerId: payoutLog.ownerId,
      amount: payoutLog.amount,
    });

    const paidRow = await db.collection("transactions").doc(txId).get();
    const pd = paidRow.data();
    const payoutPropertyId =
      typeof pd?.propertyId === "string" ? pd.propertyId.trim() : "";
    if (payoutLog.ownerId) {
      const amt = formatKwdForNotification(payoutLog.amount);
      void sendNotificationToUser({
        uid: payoutLog.ownerId,
        title: "تحويل أرباح",
        body: `💰 تم تحويل ${amt} د.ك إلى حسابك`,
        notificationType: "payout",
        data: {
          screen: "payout",
          bookingId: txId,
          transactionId: txId,
          propertyId: payoutPropertyId,
        },
      });
    }

    return { ok: true };
  }
);

/**
 * Admin: record guest refund on ledger only (no booking writes). Idempotent via refundStatus.
 * Recalculates ownerPayoutAmount from frozen netAmount and remaining gross after refund.
 */
export const processChaletBookingRefund = onCall(
  { region: "us-central1" },
  async (request) => {
    requireUid(request);
    if (!isAdminAuth(request.auth)) {
      throw new HttpsError("permission-denied", "Admin only");
    }

    const txId =
      typeof request.data?.transactionId === "string" ? request.data.transactionId.trim() : "";
    if (!txId) {
      throw new HttpsError("invalid-argument", "transactionId is required");
    }

    const refundReferenceRaw = request.data?.refundReference;
    const refundReference =
      typeof refundReferenceRaw === "string" ? refundReferenceRaw.trim() : "";

    const updatedBy = request.auth?.uid ?? "system";

    const now = admin.firestore.Timestamp.now();

    let refundAbort:
      | "corrupt_paid_with_refund"
      | "invalid"
      | "mismatch"
      | undefined;

    const out = await db.runTransaction(async (tx) => {
      const ref = db.collection("transactions").doc(txId);
      const snap = await tx.get(ref);

      if (!snap.exists) {
        throw new HttpsError("not-found", "Transaction not found");
      }

      const data = snap.data()!;
      if (data.isDeleted === true) {
        throw new HttpsError("failed-precondition", "Transaction inactive");
      }
      if (data.type !== "booking" || data.source !== "chalet_daily") {
        throw new HttpsError("failed-precondition", "Invalid transaction");
      }

      const refundStatusCur = String(data.refundStatus ?? "none");

      if (data.payoutStatus === "paid" && refundStatusCur !== "none") {
        tx.update(ref, {
          hasIssue: true,
          updatedAt: FieldValue.serverTimestamp(),
          updatedBy,
        });
        refundAbort = "corrupt_paid_with_refund";
        return null;
      }

      assertTransactionMutable(data);

      if (refundStatusCur !== "none") {
        throw new HttpsError("failed-precondition", "Already refunded");
      }

      if (data.payoutStatus === "paid") {
        throw new HttpsError("failed-precondition", "Owner already paid out");
      }

      const payoutSt = String(data.payoutStatus ?? "pending");
      if (payoutSt !== "pending") {
        throw new HttpsError("failed-precondition", "Payout not eligible for refund");
      }

      const anomaly = flagFinancialAnomalies(tx, ref, data, updatedBy);
      if (anomaly) {
        refundAbort = anomaly;
        return null;
      }

      const gross = typeof data.amount === "number" ? data.amount : Number(data.amount);
      if (!Number.isFinite(gross) || gross <= 0) {
        throw new HttpsError("failed-precondition", "Invalid transaction amount");
      }

      const netFrozen = typeof data.netAmount === "number" ? data.netAmount : Number(data.netAmount);
      if (!Number.isFinite(netFrozen) || netFrozen < 0) {
        throw new HttpsError("failed-precondition", "Invalid net amount");
      }

      let startTs: admin.firestore.Timestamp | null = null;
      const snapRaw = data.bookingSnapshot;
      if (snapRaw && typeof snapRaw === "object") {
        const s = (snapRaw as Record<string, unknown>).startDate;
        if (s instanceof admin.firestore.Timestamp) {
          startTs = s;
        }
      }
      if (!startTs) {
        const bid = typeof data.bookingId === "string" ? data.bookingId.trim() : "";
        if (!bid) {
          throw new HttpsError("failed-precondition", "Missing booking reference");
        }
        const bSnap = await tx.get(db.collection("bookings").doc(bid));
        if (!bSnap.exists) {
          throw new HttpsError("not-found", "Booking not found");
        }
        const bs = bSnap.data()?.startDate;
        if (!(bs instanceof admin.firestore.Timestamp)) {
          throw new HttpsError("failed-precondition", "Missing booking start date");
        }
        startTs = bs;
      }

      const refundAmount = computeRefundAmountGross(gross, startTs, now);
      const refundStatus: ChaletRefundStatus =
        refundAmount >= gross - 0.0005 ? "full" : "partial";
      const remainingGross = roundKwd3(Math.max(0, gross - refundAmount));
      const newOwnerPayout =
        gross > 0 ? roundKwd3(netFrozen * (remainingGross / gross)) : 0;

      if (newOwnerPayout < -LEDGER_EPS) {
        throw new HttpsError("failed-precondition", "Invalid payout calculation");
      }

      const negligible = 0.0005;
      const payoutCancelled =
        refundStatus === "full" ||
        remainingGross <= negligible ||
        newOwnerPayout <= negligible;

      const update: Record<string, unknown> = {
        refundAmount,
        refundStatus,
        status: "refunded" satisfies ChaletLedgerStatus,
        updatedAt: FieldValue.serverTimestamp(),
        updatedBy,
        refundReference,
        ownerPayoutAmount: newOwnerPayout,
        isFinalized: payoutCancelled,
      };

      if (payoutCancelled) {
        update.payoutStatus = "cancelled";
      }

      tx.update(ref, update);

      return {
        refundAmount,
        refundStatus,
        ownerPayoutAmount: newOwnerPayout,
        payoutStatus: payoutCancelled ? "cancelled" : "pending",
      };
    });

    if (refundAbort === "corrupt_paid_with_refund") {
      throw new HttpsError("failed-precondition", "Cannot refund after payout");
    }
    if (refundAbort === "invalid") {
      throw new HttpsError("failed-precondition", "Invalid financial values");
    }
    if (refundAbort === "mismatch") {
      throw new HttpsError("failed-precondition", "Ledger mismatch");
    }
    if (!out) {
      throw new HttpsError(
        "failed-precondition",
        "Could not process refund (ledger issue or inconsistent state)"
      );
    }

    console.info({
      event: "finance.refund.processed",
      transactionId: txId,
      refundAmount: out.refundAmount,
    });

    const refunded = await db.collection("transactions").doc(txId).get();
    const rd = refunded.data();
    const guestForRefund =
      typeof rd?.clientId === "string" ? rd.clientId.trim() : "";
    const refundPropertyId =
      typeof rd?.propertyId === "string" ? rd.propertyId.trim() : "";
    if (guestForRefund) {
      const refundAmt = formatKwdForNotification(out.refundAmount);
      void sendNotificationToUser({
        uid: guestForRefund,
        title: "استرجاع",
        body: `↩️ تم استرجاع مبلغ ${refundAmt} د.ك`,
        notificationType: "refund",
        data: {
          screen: "property",
          bookingId: txId,
          transactionId: txId,
          propertyId: refundPropertyId,
        },
      });
    }

    return { ok: true, ...out };
  }
);
