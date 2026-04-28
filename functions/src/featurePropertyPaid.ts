import * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret, defineString } from "firebase-functions/params";

import {
  myFatoorahGetPaymentStatusFlexible,
  rejectIfMockPaymentId,
} from "./payments/myfatoorahVerify";
import { myFatoorahApiKey } from "./payments/myfatoorahRuntime";
import { featurePlanFor } from "./payments/pricing";
import { buildFeaturedPropertyInvoiceContext } from "./invoice/resolvePaymentInvoiceContext";
import { issueFeaturedPropertyInvoice } from "./invoice/issueFeaturedPropertyInvoice";
import {
  logInvoiceSmtpDiagnostics,
  resolveInvoiceSmtp,
} from "./invoice/invoiceSmtpRuntime";

const invoiceSmtpPass = defineSecret("INVOICE_SMTP_PASS");
const invoiceSmtpHost = defineString("INVOICE_SMTP_HOST", {
  default: "smtp.gmail.com",
});
const invoiceSmtpPort = defineString("INVOICE_SMTP_PORT", { default: "465" });

const db = admin.firestore();

function requireUid(request: { auth?: { uid?: string } }): string {
  const uid = request.auth?.uid;
  if (!uid || typeof uid !== "string" || uid.trim().length === 0) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }
  return uid.trim();
}

function toFiniteNumber(x: unknown, fallback: number): number {
  if (typeof x === "number" && Number.isFinite(x)) return x;
  if (typeof x === "string") {
    const n = Number(x.trim());
    if (Number.isFinite(n)) return n;
  }
  return fallback;
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

/**
 * Callable: featurePropertyPaid
 *
 * Owner completes payment UI → calls this → server verifies with MyFatoorah
 * → atomically claims the paymentId in `payment_logs/{paymentId}` AND
 * updates `properties/{id}.featuredUntil` inside one transaction.
 *
 * The transactional claim closes the previous TOCTOU race, where the replay
 * check ran outside the transaction that wrote the property update.
 *
 * Hard guards (server-only):
 * - paymentId must NOT be a mock/fake/simulate prefix.
 * - Verified status from MyFatoorah must be `paid`/`success`.
 * - Verified currency must be KWD.
 * - Verified amount must equal the canonical plan amount (no client trust).
 * - Plan (durationDays, amountKwd) must exist in `FEATURE_PLANS`.
 */
export const featurePropertyPaid = onCall(
  {
    region: "us-central1",
    secrets: [myFatoorahApiKey, invoiceSmtpPass],
    timeoutSeconds: 300,
    memory: "1GiB",
  },
  async (request) => {
    const uid = requireUid(request);
    const data = (request.data ?? {}) as Record<string, unknown>;

    const propertyId =
      typeof data.propertyId === "string" ? data.propertyId.trim() : "";
    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId is required");
    }

    const durationDaysRaw = toFiniteNumber(data.durationDays, NaN);
    const amountRaw = toFiniteNumber(data.amountKwd, NaN);
    if (!Number.isFinite(durationDaysRaw) || !Number.isFinite(amountRaw)) {
      throw new HttpsError(
        "invalid-argument",
        "durationDays and amountKwd are required"
      );
    }
    const durationDays = Math.floor(durationDaysRaw);
    const amountKwd = round3(amountRaw);
    if (durationDays <= 0 || amountKwd <= 0) {
      throw new HttpsError("invalid-argument", "Invalid durationDays/amountKwd");
    }

    const plan = featurePlanFor(durationDays, amountKwd);
    if (!plan) {
      throw new HttpsError("invalid-argument", "Invalid plan");
    }

    const paymentId =
      typeof data.paymentId === "string" ? data.paymentId.trim() : "";
    if (!paymentId) {
      throw new HttpsError("invalid-argument", "paymentId is required");
    }
    rejectIfMockPaymentId(paymentId);

    const gateway =
      typeof data.gateway === "string" ? data.gateway.trim() : "MyFatoorah";

    // Verify with gateway (server-side). Never trust client.
    const ver = await myFatoorahGetPaymentStatusFlexible(paymentId);
    if (!ver.ok) {
      throw new HttpsError(
        "failed-precondition",
        ver.status === "disabled"
          ? "Payment system not configured yet"
          : `Payment not successful (${ver.status})`
      );
    }
    if ((ver.currency ?? "").toUpperCase() !== "KWD") {
      throw new HttpsError("failed-precondition", "Currency must be KWD");
    }
    if (ver.amountKwd == null) {
      throw new HttpsError(
        "failed-precondition",
        "Missing paid amount from gateway"
      );
    }
    // Plan price on the client is the catalogue amount; the gateway may charge
    // TotalAmount (incl. small service fee). Allow [plan, plan+2] KWD slippage.
    const paid = round3(ver.amountKwd);
    const planAmt = round3(amountKwd);
    if (paid < planAmt - 0.0001 || paid > planAmt + 2) {
      throw new HttpsError("failed-precondition", "Paid amount mismatch");
    }

    // Atomic: claim paymentId + update property in a single transaction.
    // We key the claim doc by paymentId (doc id = paymentId) so the
    // transaction's get-then-set on the same ref serves as the idempotency
    // guard — no separate "where" lookup outside the tx.
    const propRef = db.collection("properties").doc(propertyId);
    const claimRef = db.collection("payment_logs").doc(paymentId);

    const result = await db.runTransaction(async (tx) => {
      const [propSnap, claimSnap] = await Promise.all([
        tx.get(propRef),
        tx.get(claimRef),
      ]);

      if (claimSnap.exists) {
        throw new HttpsError("already-exists", "paymentId already used");
      }

      if (!propSnap.exists) {
        throw new HttpsError("not-found", "Property not found");
      }
      const p = (propSnap.data() ?? {}) as Record<string, unknown>;
      const ownerId = typeof p.ownerId === "string" ? p.ownerId.trim() : "";
      if (!ownerId) {
        throw new HttpsError(
          "failed-precondition",
          "Property ownerId is missing"
        );
      }
      if (ownerId !== uid) {
        throw new HttpsError("permission-denied", "Not your property");
      }

      const now = new Date();
      const currentRaw = p.featuredUntil;
      const current = currentRaw instanceof Timestamp ? currentRaw.toDate() : null;
      const baseDate = current && current.getTime() > now.getTime() ? current : now;
      const newFeaturedUntil = new Date(
        baseDate.getTime() + durationDays * 24 * 60 * 60 * 1000
      );

      tx.update(propRef, {
        featuredUntil: Timestamp.fromDate(newFeaturedUntil),
        updatedAt: FieldValue.serverTimestamp(),
      });

      tx.set(claimRef, {
        paymentId,
        action: "featured_ad_payment",
        newStatus: "success",
        performedBy: uid,
        timestamp: FieldValue.serverTimestamp(),
        verified: true,
        gateway,
        paymentMode: "production",
        propertyId,
        durationDays,
        amountKwd,
        currency: "KWD",
        gatewayReference: ver.reference,
      });

      return { newFeaturedUntil };
    });

    const lineTitleEn = `Property Featuring - ${durationDays} days`;
    let invoiceId: string | undefined;
    let invoiceNumber: string | undefined;
    try {
      const invCtx = await buildFeaturedPropertyInvoiceContext({
        uid,
        propertyId,
        durationDays,
        amountKwd,
        newFeaturedUntil: result.newFeaturedUntil,
      });
      if (invCtx) {
        const smtp = resolveInvoiceSmtp(
          invoiceSmtpHost.value(),
          invoiceSmtpPort.value(),
          invoiceSmtpPass.value()
        );
        logInvoiceSmtpDiagnostics("featurePropertyPaid", smtp);
        const issued = await issueFeaturedPropertyInvoice({
          db,
          paymentId,
          propertyId,
          durationDays,
          newFeaturedUntil: result.newFeaturedUntil,
          amountKwd,
          ctx: invCtx,
          smtp,
          lineTitleEn,
        });
        if (issued) {
          invoiceId = issued.invoiceId;
          invoiceNumber = issued.invoiceNumber;
        }
      }
    } catch (e) {
      console.error(
        JSON.stringify({
          tag: "featurePropertyPaid_invoice_pipeline_failed",
          propertyId,
          paymentId,
          error: e instanceof Error ? e.message : String(e),
        })
      );
    }

    return {
      success: true,
      newFeaturedUntil: result.newFeaturedUntil.toISOString(),
      newFeaturedUntilMs: result.newFeaturedUntil.getTime(),
      durationDays,
      amountKwd,
      paymentId,
      propertyId,
      invoiceId: invoiceId ?? null,
      invoiceNumber: invoiceNumber ?? null,
    };
  }
);
