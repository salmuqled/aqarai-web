import * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  calculateDealPaymentStatus,
  commissionOverpaidAmount,
  getDealCommissionDue,
  legacyIsCommissionPaid,
  toFiniteNumber,
} from "./dealPaymentStatus";

const db = admin.firestore();

/**
 * Re-sum all confirmed commission payments for a deal and rewrite mirror fields.
 * Use after backfill or if drift is suspected.
 */
export async function reconcileDealCommissionPaidTotal(dealId: string): Promise<{
  dealId: string;
  summed: number;
  due: number;
  status: string;
}> {
  const dealRef = db.collection("deals").doc(dealId);
  const qs = await db
    .collection("company_payments")
    .where("relatedType", "==", "deal")
    .where("relatedId", "==", dealId)
    .where("type", "==", "commission")
    .where("status", "==", "confirmed")
    .get();

  let summed = 0;
  for (const d of qs.docs) {
    summed += toFiniteNumber(d.data().amount, 0);
  }

  await db.runTransaction(async (tx) => {
    const dealSnap = await tx.get(dealRef);
    if (!dealSnap.exists) throw new Error(`Deal not found: ${dealId}`);
    const dealData = dealSnap.data() as Record<string, unknown>;
    const due = getDealCommissionDue(dealData);
    const status = calculateDealPaymentStatus(due, summed);
    const overpaid = commissionOverpaidAmount(due, summed);
    const paidLegacy = legacyIsCommissionPaid(status);

    const update: Record<string, unknown> = {
      commissionPaidTotalKwd: summed,
      commissionPaymentStatus: status,
      commissionOverpaidKwd: overpaid,
      isCommissionPaid: paidLegacy,
      updatedAt: FieldValue.serverTimestamp(),
    };
    if (paidLegacy) {
      update.commissionPaidAt =
        dealData.commissionPaidAt instanceof Timestamp
          ? dealData.commissionPaidAt
          : FieldValue.serverTimestamp();
    } else {
      update.commissionPaidAt = FieldValue.delete();
    }
    tx.update(dealRef, update);
  });

  const dealSnap = await dealRef.get();
  const dd = dealSnap.data() as Record<string, unknown>;
  return {
    dealId,
    summed,
    due: getDealCommissionDue(dd),
    status: String(dd.commissionPaymentStatus ?? ""),
  };
}
