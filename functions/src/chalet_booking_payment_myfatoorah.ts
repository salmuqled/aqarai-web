import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

import {
  myFatoorahApiKey,
  myFatoorahAppReturnBaseUrl,
  myFatoorahBaseUrl,
  requirePaymentEnabledOrExplain,
} from "./payments/myfatoorahRuntime";
import {
  myFatoorahGetPaymentStatusFlexible,
  type MyFatoorahVerifyResult,
} from "./payments/myfatoorahVerify";
import {
  resolveExecutePaymentSessionIds,
  type ExecutePaymentResponse,
} from "./payments/myfatoorahGateway";
import { finalizeBookingAfterPayment, pendingPaymentStillHolds } from "./chalet_booking";
import { ensureChaletLedgerForConfirmedBooking } from "./chalet_booking_finance";
import { writeExceptionLog } from "./exceptionLogs";

const db = admin.firestore();

function requireUid(request: { auth?: { uid?: string } }): string {
  const uid = request.auth?.uid;
  if (!uid || typeof uid !== "string" || uid.trim().length === 0) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }
  return uid.trim();
}

function toFiniteNumber(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

type MyFatoorahInitiatePaymentResponse = {
  IsSuccess?: boolean;
  Message?: string;
  Data?: {
    PaymentMethods?: Array<{
      PaymentMethodId?: number;
      PaymentMethodEn?: string;
      PaymentMethodAr?: string;
      IsDirectPayment?: boolean;
    }>;
  };
};

type MyFatoorahGetPaymentStatusResponse = {
  IsSuccess?: boolean;
  Message?: string;
  Data?: {
    InvoiceStatus?: string;
    InvoiceReference?: string;
    InvoiceValue?: number;
    InvoiceTransactions?: Array<{
      TransactionStatus?: string;
      PaidCurrency?: string;
      PaidCurrencyValue?: number;
      ReferenceId?: string;
    }>;
  };
};

async function myFatoorahInitiatePayment(amountKwd: number): Promise<number> {
  const apiKey = process.env.MYFATOORAH_API_KEY;
  const base = myFatoorahBaseUrl();
  requirePaymentEnabledOrExplain();

  const url = `${base}/v2/InitiatePayment`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey!.trim()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ InvoiceAmount: round3(amountKwd), CurrencyIso: "KWD" }),
  });
  const text = await res.text();
  let json: MyFatoorahInitiatePaymentResponse;
  try {
    json = JSON.parse(text) as MyFatoorahInitiatePaymentResponse;
  } catch {
    throw new HttpsError("internal", `MyFatoorah invalid JSON (http ${res.status})`);
  }
  if (!res.ok || json.IsSuccess !== true) {
    const msg = json?.Message ? String(json.Message) : `http_${res.status}`;
    throw new HttpsError("failed-precondition", `MyFatoorah error: ${msg}`);
  }
  const methods = json.Data?.PaymentMethods ?? [];
  const first = methods.find((m) => typeof m.PaymentMethodId === "number") ?? methods[0];
  const id = first?.PaymentMethodId;
  if (typeof id !== "number" || !Number.isFinite(id)) {
    throw new HttpsError("failed-precondition", "MyFatoorah: no payment methods");
  }
  return id;
}

async function myFatoorahExecutePayment(args: {
  amountKwd: number;
  paymentMethodId: number;
  bookingId: string;
  language: "AR" | "EN";
}): Promise<{ paymentUrl: string; paymentId: string; invoiceId: string | null }> {
  const apiKey = process.env.MYFATOORAH_API_KEY;
  const base = myFatoorahBaseUrl();
  requirePaymentEnabledOrExplain();

  const appReturn = myFatoorahAppReturnBaseUrl();
  const callBackUrl = `${appReturn}?${new URLSearchParams({
    s: "payment/success",
    bookingId: args.bookingId,
  }).toString()}`;
  const errorUrl = `${appReturn}?${new URLSearchParams({
    s: "payment/error",
    bookingId: args.bookingId,
  }).toString()}`;

  const url = `${base}/v2/ExecutePayment`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey!.trim()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      PaymentMethodId: args.paymentMethodId,
      InvoiceValue: round3(args.amountKwd),
      CallBackUrl: callBackUrl,
      ErrorUrl: errorUrl,
      CustomerReference: args.bookingId,
      UserDefinedField: args.bookingId,
      Language: args.language,
      DisplayCurrencyIso: "KWD",
    }),
  });

  const text = await res.text();
  let json: ExecutePaymentResponse;
  try {
    json = JSON.parse(text) as ExecutePaymentResponse;
  } catch {
    throw new HttpsError("internal", `MyFatoorah invalid JSON (http ${res.status})`);
  }
  if (!res.ok || json.IsSuccess !== true) {
    const msg = json?.Message ? String(json.Message) : `http_${res.status}`;
    throw new HttpsError("failed-precondition", `MyFatoorah error: ${msg}`);
  }

  return resolveExecutePaymentSessionIds(text, json);
}

function verifyResultToChaletShape(ver: MyFatoorahVerifyResult): {
  ok: boolean;
  status: string;
  amountKwd: number | null;
  currency: string | null;
  reference: string | null;
  raw: MyFatoorahGetPaymentStatusResponse;
} {
  return {
    ok: ver.ok,
    status: ver.status,
    amountKwd: ver.amountKwd,
    currency: ver.currency,
    reference: ver.reference,
    raw: ver.raw as MyFatoorahGetPaymentStatusResponse,
  };
}

/**
 * Callable: createBookingMyFatoorahPayment
 *
 * Creates a gateway payment URL for an existing booking in `pending_payment`.
 */
export const createBookingMyFatoorahPayment = onCall(
  { region: "us-central1", secrets: [myFatoorahApiKey] },
  async (request) => {
    const uid = requireUid(request);
    const data = (request.data ?? {}) as Record<string, unknown>;

    const bookingId = typeof data.bookingId === "string" ? data.bookingId.trim() : "";
    if (!bookingId) throw new HttpsError("invalid-argument", "bookingId is required");
    const langRaw = typeof data.lang === "string" ? data.lang.trim().toLowerCase() : "ar";
    const language: "AR" | "EN" = langRaw.startsWith("en") ? "EN" : "AR";

    const bookingRef = db.collection("bookings").doc(bookingId);
    const snap = await bookingRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Booking not found");
    const b = (snap.data() ?? {}) as Record<string, unknown>;

    const clientId = typeof b.clientId === "string" ? b.clientId.trim() : "";
    if (!clientId || clientId !== uid) {
      throw new HttpsError("permission-denied", "Not your booking");
    }
    const status = typeof b.status === "string" ? b.status.trim() : "";
    if (status !== "pending_payment") {
      throw new HttpsError("failed-precondition", "Booking is not pending_payment");
    }
    if (!pendingPaymentStillHolds(b as admin.firestore.DocumentData, Date.now())) {
      throw new HttpsError("failed-precondition", "BOOKING_PAYMENT_WINDOW_EXPIRED");
    }
    const amount = toFiniteNumber(b.totalPrice);
    if (amount == null || amount <= 0) {
      throw new HttpsError("failed-precondition", "Invalid booking totalPrice");
    }

    const paymentMethodId = await myFatoorahInitiatePayment(amount);
    const { paymentUrl, paymentId, invoiceId } = await myFatoorahExecutePayment({
      amountKwd: amount,
      paymentMethodId,
      bookingId,
      language,
    });

    await bookingRef.update({
      paymentProvider: "myfatoorah",
      paymentId,
      invoiceId,
      paymentUrl,
      paymentSessionCreatedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    return { ok: true, bookingId, paymentUrl, paymentId, invoiceId };
  }
);

/**
 * Callable: verifyBookingMyFatoorahPayment
 *
 * Server-side verification with MyFatoorah; only then sets `confirmed`.
 */
export const verifyBookingMyFatoorahPayment = onCall(
  { region: "us-central1", secrets: [myFatoorahApiKey] },
  async (request) => {
    const uid = requireUid(request);
    const data = (request.data ?? {}) as Record<string, unknown>;

    const bookingId = typeof data.bookingId === "string" ? data.bookingId.trim() : "";
    if (!bookingId) throw new HttpsError("invalid-argument", "bookingId is required");
    const paymentId = typeof data.paymentId === "string" ? data.paymentId.trim() : "";
    if (!paymentId) throw new HttpsError("invalid-argument", "paymentId is required");

    const bookingRef = db.collection("bookings").doc(bookingId);
    const snap = await bookingRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "Booking not found");
    const b0 = (snap.data() ?? {}) as Record<string, unknown>;

    const clientId = typeof b0.clientId === "string" ? b0.clientId.trim() : "";
    if (!clientId || clientId !== uid) {
      throw new HttpsError("permission-denied", "Not your booking");
    }

    const st0 = typeof b0.status === "string" ? b0.status.trim() : "";
    if (st0 === "confirmed") {
      await ensureChaletLedgerForConfirmedBooking(bookingId);
      return { ok: true, bookingId, status: "confirmed" };
    }
    if (st0 !== "pending_payment") {
      throw new HttpsError("failed-precondition", "Booking is not pending_payment");
    }
    if (!pendingPaymentStillHolds(b0 as admin.firestore.DocumentData, Date.now())) {
      throw new HttpsError("failed-precondition", "BOOKING_PAYMENT_WINDOW_EXPIRED");
    }

    const amount = toFiniteNumber(b0.totalPrice);
    if (amount == null || amount <= 0) {
      throw new HttpsError("failed-precondition", "Invalid booking totalPrice");
    }

    if (paymentId.startsWith("fake_")) {
      throw new HttpsError("failed-precondition", "Invalid paymentId");
    }

    const ver = verifyResultToChaletShape(
      await myFatoorahGetPaymentStatusFlexible(paymentId)
    );
    if (!ver.ok) {
      throw new HttpsError("failed-precondition", `PAYMENT_NOT_SUCCESSFUL:${ver.status}`);
    }
    if ((ver.currency ?? "").toUpperCase() !== "KWD") {
      throw new HttpsError("failed-precondition", "Currency must be KWD");
    }
    if (ver.amountKwd == null) {
      throw new HttpsError("failed-precondition", "Missing paid amount from gateway");
    }
    if (round3(ver.amountKwd) !== round3(amount)) {
      throw new HttpsError("failed-precondition", "Paid amount mismatch");
    }

    try {
      await finalizeBookingAfterPayment(bookingId, {
        kind: "myfatoorah",
        uid,
        paymentId,
        paymentGatewayStatus: ver.status,
      });
    } catch (err: unknown) {
      if (!(err instanceof HttpsError)) {
        void writeExceptionLog({
          type: "ledger_error",
          relatedId: bookingId,
          message: `myfatoorah confirm tx: ${err instanceof Error ? err.message : String(err)}`,
          severity: "high",
        });
      }
      throw err;
    }

    return { ok: true, bookingId, status: "confirmed" };
  }
);

/**
 * Callable: cancelBookingPendingPayment
 *
 * Cancels a booking still in `pending_payment` (user cancelled / payment failed in UI).
 */
export const cancelBookingPendingPayment = onCall(
  { region: "us-central1" },
  async (request) => {
    const uid = requireUid(request);
    const data = (request.data ?? {}) as Record<string, unknown>;

    const bookingId = typeof data.bookingId === "string" ? data.bookingId.trim() : "";
    if (!bookingId) throw new HttpsError("invalid-argument", "bookingId is required");

    const bookingRef = db.collection("bookings").doc(bookingId);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(bookingRef);
      if (!snap.exists) throw new HttpsError("not-found", "Booking not found");
      const b = (snap.data() ?? {}) as Record<string, unknown>;

      const clientId = typeof b.clientId === "string" ? b.clientId.trim() : "";
      if (!clientId || clientId !== uid) {
        throw new HttpsError("permission-denied", "Not your booking");
      }
      const status = typeof b.status === "string" ? b.status.trim() : "";
      if (status !== "pending_payment") return;

      tx.update(bookingRef, {
        status: "cancelled",
        cancelledAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });

    return { ok: true, bookingId, status: "cancelled" };
  }
);
