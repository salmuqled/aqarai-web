import * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { isPaymentEnabled } from "./payments/myfatoorahRuntime";

const db = admin.firestore();

type FeaturePlan = { durationDays: number; priceKwd: number };

const PLANS: FeaturePlan[] = [
  { durationDays: 3, priceKwd: 5 },
  { durationDays: 7, priceKwd: 10 },
  { durationDays: 14, priceKwd: 15 },
  { durationDays: 30, priceKwd: 25 },
];

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

function planFor(durationDays: number, amountKwd: number): FeaturePlan | null {
  for (const p of PLANS) {
    if (p.durationDays === durationDays && p.priceKwd === amountKwd) return p;
  }
  return null;
}

type MyFatoorahGetPaymentStatusResponse = {
  IsSuccess?: boolean;
  Message?: string;
  Data?: {
    InvoiceStatus?: string;
    InvoiceId?: number;
    InvoiceReference?: string;
    CustomerReference?: string;
    InvoiceValue?: number;
    InvoiceTransactions?: Array<{
      TransactionStatus?: string;
      PaidCurrency?: string;
      PaidCurrencyValue?: number;
      PaymentId?: string | number;
      AuthorizationID?: string;
      ReferenceId?: string;
      TrackId?: string;
      TransactionId?: string;
      Error?: string;
    }>;
  };
};

function normalizeStatus(s: unknown): string {
  return typeof s === "string" ? s.trim().toLowerCase() : "";
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

async function myFatoorahGetPaymentStatus(paymentId: string): Promise<{
  ok: boolean;
  status: string;
  amountKwd: number | null;
  currency: string | null;
  reference: string | null;
  raw: MyFatoorahGetPaymentStatusResponse;
}> {
  const apiKey = process.env.MYFATOORAH_API_KEY;
  const base = (process.env.MYFATOORAH_API_BASE_URL ?? "https://api.myfatoorah.com")
    .trim()
    .replace(/\/+$/, "");
  if (!isPaymentEnabled()) {
    console.warn(
      "[featurePropertyPaid] MyFatoorah disabled: missing MYFATOORAH_API_KEY or set to test_key"
    );
    return {
      ok: false,
      status: "disabled",
      amountKwd: null,
      currency: null,
      reference: null,
      raw: { IsSuccess: false, Message: "Payment system not configured yet" },
    };
  }

  const url = `${base}/v2/GetPaymentStatus`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey!.trim()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ Key: paymentId, KeyType: "PaymentId" }),
  });

  const text = await res.text();
  let json: MyFatoorahGetPaymentStatusResponse;
  try {
    json = JSON.parse(text) as MyFatoorahGetPaymentStatusResponse;
  } catch {
    throw new HttpsError(
      "internal",
      `MyFatoorah invalid JSON (http ${res.status})`
    );
  }

  if (!res.ok) {
    const msg = json?.Message ? String(json.Message) : `http_${res.status}`;
    throw new HttpsError("failed-precondition", `MyFatoorah error: ${msg}`);
  }

  const isSuccess = json.IsSuccess === true;
  const data = json.Data;
  const invoiceStatus = normalizeStatus(data?.InvoiceStatus);
  const tx = data?.InvoiceTransactions && data.InvoiceTransactions.length > 0
    ? data.InvoiceTransactions[0]
    : undefined;
  const txStatus = normalizeStatus(tx?.TransactionStatus);

  const currency = typeof tx?.PaidCurrency === "string" ? tx!.PaidCurrency!.trim() : null;
  const amount = typeof tx?.PaidCurrencyValue === "number" && Number.isFinite(tx.PaidCurrencyValue)
    ? round3(tx.PaidCurrencyValue)
    : (typeof data?.InvoiceValue === "number" && Number.isFinite(data.InvoiceValue) ? round3(data.InvoiceValue) : null);

  const ok =
    isSuccess &&
    (invoiceStatus === "paid" || invoiceStatus === "success") &&
    (txStatus === "" || txStatus === "succss" || txStatus === "success");

  const reference =
    (typeof data?.InvoiceReference === "string" && data.InvoiceReference.trim())
      ? data.InvoiceReference.trim()
      : (typeof tx?.ReferenceId === "string" && tx.ReferenceId.trim())
        ? tx.ReferenceId.trim()
        : null;

  return {
    ok,
    status: invoiceStatus || txStatus || "unknown",
    amountKwd: amount,
    currency,
    reference,
    raw: json,
  };
}

/**
 * Callable: featurePropertyPaid
 *
 * Client completes payment UI, then calls this to:
 * - validate owner
 * - verify payment with MyFatoorah (server-side)
 * - log to payment_logs
 * - update properties/{id}.featuredUntil
 */
export const featurePropertyPaid = onCall(
  { region: "us-central1" },
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
      throw new HttpsError("invalid-argument", "durationDays and amountKwd are required");
    }
    const durationDays = Math.floor(durationDaysRaw);
    const amountKwd = Math.round(amountRaw * 1000) / 1000;
    if (durationDays <= 0 || amountKwd <= 0) {
      throw new HttpsError("invalid-argument", "Invalid durationDays/amountKwd");
    }

    if (!planFor(durationDays, amountKwd)) {
      throw new HttpsError("invalid-argument", "Invalid plan");
    }

    const paymentId =
      typeof data.paymentId === "string" ? data.paymentId.trim() : "";
    if (!paymentId) {
      throw new HttpsError("invalid-argument", "paymentId is required");
    }
    const gateway =
      typeof data.gateway === "string" ? data.gateway.trim() : "MyFatoorah";

    const propRef = db.collection("properties").doc(propertyId);
    const snap = await propRef.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Property not found");
    }
    const p = (snap.data() ?? {}) as Record<string, unknown>;
    const ownerId = typeof p.ownerId === "string" ? p.ownerId.trim() : "";
    if (!ownerId) {
      throw new HttpsError("failed-precondition", "Property ownerId is missing");
    }
    if (ownerId !== uid) {
      throw new HttpsError("permission-denied", "Not your property");
    }

    // Replay protection: paymentId must be single-use.
    const used = await db
      .collection("payment_logs")
      .where("paymentId", "==", paymentId)
      .limit(1)
      .get();
    if (!used.empty) {
      throw new HttpsError("already-exists", "paymentId already used");
    }

    // Verify with gateway (server-side). Never trust client.
    // Production only: reject mock ids and verify via MyFatoorah.
    if (paymentId.startsWith("fake_")) {
      throw new HttpsError("failed-precondition", "Invalid paymentId");
    }
    const ver = await myFatoorahGetPaymentStatus(paymentId);

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
      throw new HttpsError("failed-precondition", "Missing paid amount from gateway");
    }
    if (round3(ver.amountKwd) !== round3(amountKwd)) {
      throw new HttpsError("failed-precondition", "Paid amount mismatch");
    }

    const now = new Date();
    const currentRaw = p.featuredUntil;
    const current = currentRaw instanceof Timestamp ? currentRaw.toDate() : null;
    const baseDate = current && current.getTime() > now.getTime() ? current : now;
    const newFeaturedUntil = new Date(
      baseDate.getTime() + durationDays * 24 * 60 * 60 * 1000,
    );

    const batch = db.batch();

    batch.update(propRef, {
      featuredUntil: Timestamp.fromDate(newFeaturedUntil),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Payment log: append-only, server-written.
    const logRef = db.collection("payment_logs").doc();
    batch.set(logRef, {
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

    await batch.commit();

    return {
      success: true,
      newFeaturedUntil: newFeaturedUntil.toISOString(),
      newFeaturedUntilMs: newFeaturedUntil.getTime(),
      durationDays,
      amountKwd,
      paymentId,
      propertyId,
    };
  }
);

