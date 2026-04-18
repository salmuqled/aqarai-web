/**
 * Aggregates platform booking commission metrics from admin_ledger (source of truth).
 * Trigger: admin_ledger/{entryId} onCreate — only type "booking_commission".
 *
 * Writes (single transaction, idempotent):
 * - admin_metrics/finance — all-time
 * - admin_metrics_daily/{YYYY-MM-DD} — Asia/Kuwait calendar day from createdAt
 * - admin_metrics_monthly/{YYYY-MM} — Asia/Kuwait calendar month from createdAt
 *
 * Idempotency: admin_metrics_booking_commission_applied/{entryId}
 */
import * as admin from "firebase-admin";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { DateTime } from "luxon";

import { writeExceptionLog } from "./exceptionLogs";

const REGION = "us-central1";

const ADMIN_METRICS_FINANCE = "admin_metrics";
const FINANCE_DOC = "finance";
const DAILY_COLLECTION = "admin_metrics_daily";
const MONTHLY_COLLECTION = "admin_metrics_monthly";

/** Ledger entry doc id — stable idempotency key (not bookingId). */
const APPLIED_COLLECTION = "admin_metrics_booking_commission_applied";

const METRICS_ZONE = "Asia/Kuwait";

function str(v: unknown): string {
  if (v == null) return "";
  return String(v).trim();
}

function num(v: unknown): number {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

function coerceLedgerDate(data: Record<string, unknown>): Date {
  const c = data.createdAt;
  if (c instanceof Timestamp) {
    return c.toDate();
  }
  if (
    c != null &&
    typeof c === "object" &&
    typeof (c as { toDate?: () => Date }).toDate === "function"
  ) {
    return (c as { toDate: () => Date }).toDate();
  }
  return new Date();
}

/** Calendar keys in Asia/Kuwait for the ledger instant. */
function kuwaitDayAndMonthKeys(instant: Date): { dayKey: string; monthKey: string } {
  const dt = DateTime.fromMillis(instant.getTime()).setZone(METRICS_ZONE);
  return {
    dayKey: dt.toFormat("yyyy-MM-dd"),
    monthKey: dt.toFormat("yyyy-MM"),
  };
}

function bumpRollup(
  tx: FirebaseFirestore.Transaction,
  snap: FirebaseFirestore.DocumentSnapshot,
  ref: FirebaseFirestore.DocumentReference,
  commissionAmount: number,
  extra: Record<string, unknown>
): void {
  if (!snap.exists) {
    tx.set(ref, {
      ...extra,
      totalRevenue: commissionAmount,
      totalCommission: commissionAmount,
      totalBookings: 1,
      updatedAt: FieldValue.serverTimestamp(),
    });
  } else {
    tx.update(ref, {
      totalRevenue: FieldValue.increment(commissionAmount),
      totalCommission: FieldValue.increment(commissionAmount),
      totalBookings: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
    });
  }
}

export const onAdminLedgerCreatedFinanceMetrics = onDocumentCreated(
  {
    region: REGION,
    document: "admin_ledger/{entryId}",
    retry: true,
  },
  async (event) => {
    const entryId = event.params.entryId as string;
    const snap = event.data;
    if (!snap) {
      logger.warn("admin_ledger.metrics: missing snapshot", { entryId });
      return;
    }

    const data = snap.data() as Record<string, unknown>;
    const type = str(data.type);
    if (type !== "booking_commission") {
      return;
    }

    const commissionAmount = num(data.amount);
    const bookingId = str(data.bookingId);
    if (!bookingId) {
      logger.warn("admin_ledger.metrics: missing bookingId", { entryId, type });
      return;
    }

    const at = coerceLedgerDate(data);
    const { dayKey, monthKey } = kuwaitDayAndMonthKeys(at);

    const db = admin.firestore();
    const financeRef = db.collection(ADMIN_METRICS_FINANCE).doc(FINANCE_DOC);
    const appliedRef = db.collection(APPLIED_COLLECTION).doc(entryId);
    const dailyRef = db.collection(DAILY_COLLECTION).doc(dayKey);
    const monthlyRef = db.collection(MONTHLY_COLLECTION).doc(monthKey);

    try {
      await db.runTransaction(async (tx) => {
        const appliedSnap = await tx.get(appliedRef);
        if (appliedSnap.exists) {
          return;
        }

        const financeSnap = await tx.get(financeRef);
        const dailySnap = await tx.get(dailyRef);
        const monthlySnap = await tx.get(monthlyRef);

        tx.set(appliedRef, {
          ledgerEntryId: entryId,
          bookingId,
          commissionAmount,
          dayKey,
          monthKey,
          appliedAt: FieldValue.serverTimestamp(),
        });

        if (!financeSnap.exists) {
          tx.set(financeRef, {
            totalRevenue: commissionAmount,
            totalCommission: commissionAmount,
            totalBookings: 1,
            updatedAt: FieldValue.serverTimestamp(),
            lastBookingIdProcessed: bookingId,
            lastLedgerEntryIdProcessed: entryId,
          });
        } else {
          tx.update(financeRef, {
            totalRevenue: FieldValue.increment(commissionAmount),
            totalCommission: FieldValue.increment(commissionAmount),
            totalBookings: FieldValue.increment(1),
            updatedAt: FieldValue.serverTimestamp(),
            lastBookingIdProcessed: bookingId,
            lastLedgerEntryIdProcessed: entryId,
          });
        }

        bumpRollup(tx, dailySnap, dailyRef, commissionAmount, { date: dayKey });
        bumpRollup(tx, monthlySnap, monthlyRef, commissionAmount, {
          month: monthKey,
        });
      });
    } catch (e) {
      logger.error("admin_ledger.metrics: transaction failed", {
        entryId,
        bookingId,
        dayKey,
        monthKey,
        err: String(e),
      });
      void writeExceptionLog({
        type: "ledger_error",
        relatedId: entryId,
        message: `admin_metrics rollup booking=${bookingId}: ${e instanceof Error ? e.message : String(e)}`,
        severity: "high",
      });
      throw e;
    }

    logger.info("admin_ledger.metrics: applied", {
      entryId,
      bookingId,
      commissionAmount,
      dayKey,
      monthKey,
    });
  }
);
