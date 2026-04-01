/**
 * Unified audit trail for `company_payments`: created + status_changed logs
 * written only by Cloud Functions (Admin SDK). performedBy uses updatedBy when set.
 */
import * as admin from "firebase-admin";
import {
  onDocumentCreated,
  onDocumentUpdated,
} from "firebase-functions/v2/firestore";
import { FieldValue } from "firebase-admin/firestore";

const VALID_STATUSES = new Set(["pending", "confirmed", "rejected"]);

function performedByFromPayment(
  data: Record<string, unknown> | undefined
): string {
  if (!data) return "system";
  const u = data.updatedBy;
  if (typeof u === "string" && u.trim().length > 0) {
    return u.trim();
  }
  return "system";
}

/** Fallback when created log has no updatedBy (legacy / malformed). */
function performedByForCreated(
  data: Record<string, unknown> | undefined
): string {
  if (!data) return "system";
  const u = data.updatedBy;
  if (typeof u === "string" && u.trim().length > 0) {
    return u.trim();
  }
  const c = data.createdBy;
  if (typeof c === "string" && c.trim().length > 0) {
    return c.trim();
  }
  return "system";
}

export const onCompanyPaymentCreatedLog = onDocumentCreated(
  {
    document: "company_payments/{paymentId}",
    region: "us-central1",
  },
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const after = snap.data() as Record<string, unknown>;
    const newStatus =
      after.status != null ? String(after.status) : undefined;
    if (newStatus === undefined || !VALID_STATUSES.has(newStatus)) return;

    const paymentId = event.params.paymentId;
    if (!paymentId || typeof paymentId !== "string") return;

    await admin.firestore().collection("payment_logs").add({
      paymentId,
      action: "created",
      newStatus,
      performedBy: performedByForCreated(after),
      timestamp: FieldValue.serverTimestamp(),
    });
  }
);

export const onCompanyPaymentUpdatedLogStatus = onDocumentUpdated(
  {
    document: "company_payments/{paymentId}",
    region: "us-central1",
  },
  async (event) => {
    const change = event.data;
    if (!change) return;

    const before = change.before.data() as Record<string, unknown> | undefined;
    const after = change.after.data() as Record<string, unknown> | undefined;
    if (!after) return;

    const oldStatus =
      before?.status != null ? String(before.status) : undefined;
    const newStatus =
      after.status != null ? String(after.status) : undefined;

    if (newStatus === undefined || oldStatus === newStatus) return;

    if (!VALID_STATUSES.has(newStatus)) return;

    const paymentId = event.params.paymentId;
    if (!paymentId || typeof paymentId !== "string") return;

    const log: Record<string, unknown> = {
      paymentId,
      action: "status_changed",
      newStatus,
      performedBy: performedByFromPayment(after),
      timestamp: FieldValue.serverTimestamp(),
    };

    if (oldStatus !== undefined && VALID_STATUSES.has(oldStatus)) {
      log.oldStatus = oldStatus;
    }

    await admin.firestore().collection("payment_logs").add(log);
  }
);
