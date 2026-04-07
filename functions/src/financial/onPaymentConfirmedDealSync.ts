import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { logger } from "firebase-functions";

import {
  calculateDealPaymentStatus,
  commissionOverpaidAmount,
  getDealCommissionDue,
  isFinalizedDealStatus,
  legacyIsCommissionPaid,
  toFiniteNumber,
} from "./dealPaymentStatus";

const db = admin.firestore();

type PaymentStatus = "pending" | "confirmed" | "rejected";

function paymentStatus(v: unknown): PaymentStatus | null {
  if (v === "pending" || v === "confirmed" || v === "rejected") return v;
  return null;
}

function isCommissionDealPayment(data: Record<string, unknown>): boolean {
  return data.type === "commission" && data.relatedType === "deal";
}

function deltaForTransition(
  before: PaymentStatus | null,
  after: PaymentStatus | null,
  amount: number,
): number {
  const wasConfirmed = before === "confirmed";
  const isConfirmed = after === "confirmed";
  if (!wasConfirmed && isConfirmed) return amount;
  if (wasConfirmed && !isConfirmed) return -amount;
  return 0;
}

/**
 * On any company_payments write, adjust linked deal commission mirrors when
 * status crosses in/out of "confirmed". Idempotent per transition.
 */
export const onCompanyPaymentDealFinancialSync = onDocumentWritten(
  {
    document: "company_payments/{paymentId}",
    region: "us-central1",
  },
  async (event) => {
    const before = event.data?.before.data() as Record<string, unknown> | undefined;
    const after = event.data?.after.data() as Record<string, unknown> | undefined;

    // Deleted doc: treat as un-confirm if was confirmed
    const beforeStatus = before ? paymentStatus(before.status) : null;
    const afterStatus = after ? paymentStatus(after.status) : null;

    const payload = after ?? before;
    if (!payload || !isCommissionDealPayment(payload)) return;

    const relatedId = typeof payload.relatedId === "string" ? payload.relatedId : "";
    if (!relatedId) {
      logger.error("Commission payment missing relatedId", {
        paymentId: event.params.paymentId,
      });
      return;
    }

    const amount = toFiniteNumber(payload.amount, 0);
    if (amount <= 0) {
      logger.error("Commission payment invalid amount", {
        paymentId: event.params.paymentId,
        amount: payload.amount,
      });
      return;
    }

    const delta = deltaForTransition(beforeStatus, afterStatus, amount);
    if (delta === 0) return;

    const dealRef = db.collection("deals").doc(relatedId);

    try {
      await db.runTransaction(async (tx) => {
        const dealSnap = await tx.get(dealRef);
        if (!dealSnap.exists) {
          throw new Error(`Deal not found: ${relatedId}`);
        }
        const dealData = dealSnap.data() as Record<string, unknown>;
        if (!isFinalizedDealStatus(dealData.dealStatus)) {
          throw new Error(
            `Deal ${relatedId} not finalized; cannot apply commission payment`,
          );
        }

        const due = getDealCommissionDue(dealData);
        const prevPaid = toFiniteNumber(dealData.commissionPaidTotalKwd, 0);
        const nextPaid = prevPaid + delta;
        if (nextPaid < -0.0001) {
          throw new Error(
            `commissionPaidTotalKwd would go negative for deal ${relatedId}`,
          );
        }

        const status = calculateDealPaymentStatus(due, nextPaid);
        const overpaid = commissionOverpaidAmount(due, nextPaid);
        const paidLegacy = legacyIsCommissionPaid(status);

        const update: Record<string, unknown> = {
          commissionPaidTotalKwd: nextPaid,
          commissionPaymentStatus: status,
          commissionOverpaidKwd: overpaid,
          isCommissionPaid: paidLegacy,
          updatedAt: FieldValue.serverTimestamp(),
        };

        if (paidLegacy && !dealData.commissionPaidAt) {
          update.commissionPaidAt = FieldValue.serverTimestamp();
        }
        if (!paidLegacy && beforeStatus === "confirmed" && afterStatus !== "confirmed") {
          update.commissionPaidAt = FieldValue.delete();
        }

        if (delta > 0) {
          update.commissionLastPaymentAt = FieldValue.serverTimestamp();
        }

        tx.update(dealRef, update);
      });
    } catch (e) {
      logger.error("Deal financial sync failed", {
        paymentId: event.params.paymentId,
        relatedId,
        delta,
        error: e instanceof Error ? e.message : String(e),
      });
      throw e;
    }
  },
);
