import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

import {
  calculateDealPaymentStatus,
  getDealCommissionDue,
  isFinalizedDealStatus,
  toFiniteNumber,
} from "./dealPaymentStatus";
import { reconcileDealCommissionPaidTotal } from "./reconcileDealCommission";

const db = admin.firestore();

function assertAdmin(request: { auth?: { uid: string; token: Record<string, unknown> } }): string {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }
  const t = request.auth.token;
  if (t.admin !== true && t.admin !== "true") {
    throw new HttpsError("permission-denied", "Admin only");
  }
  return request.auth.uid;
}

const PAYMENT_TYPES = new Set(["auction_fee", "commission", "other"]);
const PAYMENT_REASONS = new Set(["sale", "rent", "auction", "management_fee", "other"]);
const PAYMENT_SOURCES = new Set(["bank_transfer", "certified_check", "cash"]);
const RELATED_TYPES = new Set(["auction_request", "deal", "manual"]);
const STATUSES = new Set(["pending", "confirmed", "rejected"]);

function assertValidReferenceDocumentId(id: string): void {
  const t = id.trim();
  if (!t) throw new HttpsError("invalid-argument", "referenceNumber required");
  if (t.includes("/")) {
    throw new HttpsError("invalid-argument", "referenceNumber must not contain /");
  }
  if (t === "." || t === "..") {
    throw new HttpsError("invalid-argument", "invalid referenceNumber");
  }
  if (t.length > 512) {
    throw new HttpsError("invalid-argument", "referenceNumber too long");
  }
}

/**
 * Optional trusted path: same invariants as Firestore rules + deal exists for commission.
 * Prevents duplicate bank/check IDs via transaction.
 */
export const addCompanyPaymentAdmin = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = assertAdmin(request);
    const d = (request.data ?? {}) as Record<string, unknown>;

    const amount = toFiniteNumber(d.amount, NaN);
    const status = d.status;
    const type = d.type;
    const reason = d.reason;
    const source = d.source;
    const relatedType = d.relatedType;
    const notes = d.notes;
    const relatedId = typeof d.relatedId === "string" ? d.relatedId.trim() : "";
    const referenceNumber =
      typeof d.referenceNumber === "string" ? d.referenceNumber.trim() : "";
    const idempotencyKey =
      typeof d.idempotencyKey === "string" ? d.idempotencyKey.trim() : "";

    if (!Number.isFinite(amount) || amount <= 0) {
      throw new HttpsError("invalid-argument", "amount must be a positive number");
    }
    if (typeof status !== "string" || !STATUSES.has(status)) {
      throw new HttpsError("invalid-argument", "invalid status");
    }
    if (typeof type !== "string" || !PAYMENT_TYPES.has(type)) {
      throw new HttpsError("invalid-argument", "invalid type");
    }
    if (typeof reason !== "string" || !PAYMENT_REASONS.has(reason)) {
      throw new HttpsError("invalid-argument", "invalid reason");
    }
    if (typeof source !== "string" || !PAYMENT_SOURCES.has(source)) {
      throw new HttpsError("invalid-argument", "invalid source");
    }
    if (typeof relatedType !== "string" || !RELATED_TYPES.has(relatedType)) {
      throw new HttpsError("invalid-argument", "invalid relatedType");
    }
    if (typeof notes !== "string") {
      throw new HttpsError("invalid-argument", "notes must be string");
    }

    if (type === "auction_fee") {
      if (relatedType !== "auction_request" || !relatedId) {
        throw new HttpsError(
          "invalid-argument",
          "auction_fee requires relatedType auction_request and relatedId",
        );
      }
    } else if (type === "commission") {
      if (relatedType !== "deal" || !relatedId) {
        throw new HttpsError(
          "invalid-argument",
          "commission requires relatedType deal and relatedId",
        );
      }
      const dealSnap = await db.collection("deals").doc(relatedId).get();
      if (!dealSnap.exists) {
        throw new HttpsError("not-found", "Deal not found for commission payment");
      }
      const dealData = dealSnap.data() as Record<string, unknown>;
      if (!isFinalizedDealStatus(dealData.dealStatus)) {
        throw new HttpsError(
          "failed-precondition",
          "Deal must be signed or closed before commission payment",
        );
      }
    } else if (type === "other") {
      if (relatedType !== "manual") {
        throw new HttpsError("invalid-argument", "other requires relatedType manual");
      }
    }

    const needsRef = source === "bank_transfer" || source === "certified_check";
    if (needsRef) {
      assertValidReferenceDocumentId(referenceNumber);
    }

    const col = db.collection("company_payments");

    const baseData: Record<string, unknown> = {
      amount,
      status,
      type,
      reason,
      source,
      relatedType,
      notes,
      createdAt: FieldValue.serverTimestamp(),
      createdBy: uid,
      updatedBy: uid,
    };
    if (relatedId) baseData.relatedId = relatedId;

    if (idempotencyKey) {
      if (idempotencyKey.length > 200) {
        throw new HttpsError("invalid-argument", "idempotencyKey too long");
      }
      const keyRef = db.collection("company_payment_idempotency").doc(idempotencyKey);
      const existingKey = await keyRef.get();
      if (existingKey.exists) {
        const pid = existingKey.data()?.paymentId;
        if (typeof pid === "string") {
          return { ok: true, paymentId: pid, duplicate: true };
        }
      }
    }

    if (needsRef) {
      baseData.referenceNumber = referenceNumber;
      const docRef = col.doc(referenceNumber);
      const paymentId = await db.runTransaction(async (tx) => {
        const snap = await tx.get(docRef);
        if (snap.exists) {
          throw new HttpsError("already-exists", "Duplicate referenceNumber");
        }
        tx.set(docRef, baseData);
        return docRef.id;
      });
      if (idempotencyKey) {
        await db
          .collection("company_payment_idempotency")
          .doc(idempotencyKey)
          .set({
            paymentId,
            createdAt: FieldValue.serverTimestamp(),
          });
      }
      return { ok: true, paymentId, duplicate: false };
    }

    if (referenceNumber) {
      throw new HttpsError(
        "invalid-argument",
        "referenceNumber must be empty for cash source",
      );
    }

    const docRef = col.doc();
    await docRef.set(baseData);
    if (idempotencyKey) {
      await db
        .collection("company_payment_idempotency")
        .doc(idempotencyKey)
        .set({
          paymentId: docRef.id,
          createdAt: FieldValue.serverTimestamp(),
        });
    }
    return { ok: true, paymentId: docRef.id, duplicate: false };
  },
);

export const reconcileDealCommissionPaymentTotals = onCall(
  { region: "us-central1" },
  async (request) => {
    assertAdmin(request);
    const dealId = request.data?.dealId;
    if (typeof dealId !== "string" || !dealId.trim()) {
      throw new HttpsError("invalid-argument", "dealId required");
    }
    try {
      const result = await reconcileDealCommissionPaidTotal(dealId.trim());
      return { ok: true, ...result };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes("not found")) {
        throw new HttpsError("not-found", msg);
      }
      throw new HttpsError("internal", msg);
    }
  },
);

/**
 * Read-only diagnostic: due vs paid mirror vs recompute from payments (no write).
 */
export const getDealCommissionPaymentDiagnostics = onCall(
  { region: "us-central1" },
  async (request) => {
    assertAdmin(request);
    const dealId = request.data?.dealId;
    if (typeof dealId !== "string" || !dealId.trim()) {
      throw new HttpsError("invalid-argument", "dealId required");
    }
    const id = dealId.trim();
    const dealSnap = await db.collection("deals").doc(id).get();
    if (!dealSnap.exists) {
      throw new HttpsError("not-found", "Deal not found");
    }
    const dealData = dealSnap.data() as Record<string, unknown>;
    const due = getDealCommissionDue(dealData);
    const mirrorPaid = toFiniteNumber(dealData.commissionPaidTotalKwd, 0);
    const mirrorStatus = String(dealData.commissionPaymentStatus ?? "");

    const qs = await db
      .collection("company_payments")
      .where("relatedType", "==", "deal")
      .where("relatedId", "==", id)
      .where("type", "==", "commission")
      .where("status", "==", "confirmed")
      .get();
    let summed = 0;
    for (const d of qs.docs) {
      summed += toFiniteNumber(d.data().amount, 0);
    }
    const computedStatus = calculateDealPaymentStatus(due, summed);
    return {
      dealId: id,
      due,
      commissionPaidTotalKwdMirror: mirrorPaid,
      commissionPaymentStatusMirror: mirrorStatus,
      summedFromPayments: summed,
      computedStatusFromPayments: computedStatus,
      drift: Math.abs(mirrorPaid - summed) > 0.01,
    };
  },
);
