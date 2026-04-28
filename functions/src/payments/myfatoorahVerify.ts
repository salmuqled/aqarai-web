/**
 * Single source of truth for `GetPaymentStatus` calls against the MyFatoorah
 * gateway. Used by every server-side verification path:
 *   - `verifyBookingMyFatoorahPayment` (chalet bookings)
 *   - `featurePropertyPaid` (featured ad payments)
 *   - `markAuctionFeePaid` (auction listing fees)
 *   - `myFatoorahWebhook` (gateway → backend notifications)
 *
 * NEVER trust client-supplied payment status. The truth comes from this call.
 */
import { HttpsError } from "firebase-functions/v2/https";
import { isPaymentEnabled, myFatoorahBaseUrl } from "./myfatoorahRuntime";

export type MyFatoorahGetPaymentStatusResponse = {
  IsSuccess?: boolean;
  Message?: string;
  Data?: {
    InvoiceStatus?: string;
    InvoiceId?: number;
    InvoiceReference?: string;
    CustomerReference?: string;
    UserDefinedField?: string;
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

export interface MyFatoorahVerifyResult {
  ok: boolean;
  status: string;
  amountKwd: number | null;
  currency: string | null;
  reference: string | null;
  customerReference: string | null;
  userDefinedField: string | null;
  invoiceId: string | null;
  raw: MyFatoorahGetPaymentStatusResponse;
}

function normalizeStatus(s: unknown): string {
  return typeof s === "string" ? s.trim().toLowerCase() : "";
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

function strOrNull(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t.length > 0 ? t : null;
}

/**
 * Calls `GetPaymentStatus` with [paymentId] (KeyType = `PaymentId`) and
 * returns a normalized verification result. Throws [HttpsError] when the
 * gateway is unreachable / responds with a transport-level error so callers
 * can surface a `failed-precondition` to clients.
 */
export async function myFatoorahGetPaymentStatus(
  paymentId: string
): Promise<MyFatoorahVerifyResult> {
  return getPaymentStatusByKey(paymentId, "PaymentId");
}

/** Same as [myFatoorahGetPaymentStatus] but keyed by InvoiceId. */
export async function myFatoorahGetPaymentStatusByInvoiceId(
  invoiceId: string
): Promise<MyFatoorahVerifyResult> {
  return getPaymentStatusByKey(invoiceId, "InvoiceId");
}

/**
 * Resolves status by gateway [PaymentId], or by [InvoiceId] when the session
 * id was returned as [inv:<invoiceId>] (some MyFatoorah accounts omit
 * [Data.PaymentId] on [ExecutePayment] and only return [InvoiceId]).
 */
export async function myFatoorahGetPaymentStatusFlexible(
  paymentId: string
): Promise<MyFatoorahVerifyResult> {
  const t = paymentId.trim();
  if (t.toLowerCase().startsWith("inv:")) {
    return myFatoorahGetPaymentStatusByInvoiceId(t.slice(4).trim());
  }
  return myFatoorahGetPaymentStatus(t);
}

async function getPaymentStatusByKey(
  key: string,
  keyType: "PaymentId" | "InvoiceId"
): Promise<MyFatoorahVerifyResult> {
  const apiKey = process.env.MYFATOORAH_API_KEY;
  const base = myFatoorahBaseUrl();

  if (!isPaymentEnabled()) {
    console.warn(
      "[myfatoorahVerify] disabled: missing MYFATOORAH_API_KEY or set to test_key"
    );
    return {
      ok: false,
      status: "disabled",
      amountKwd: null,
      currency: null,
      reference: null,
      customerReference: null,
      userDefinedField: null,
      invoiceId: null,
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
    body: JSON.stringify({ Key: key, KeyType: keyType }),
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
  const tx =
    data?.InvoiceTransactions && data.InvoiceTransactions.length > 0
      ? data.InvoiceTransactions[0]
      : undefined;
  const txStatus = normalizeStatus(tx?.TransactionStatus);

  const currency = strOrNull(tx?.PaidCurrency);
  const amount =
    typeof tx?.PaidCurrencyValue === "number" &&
    Number.isFinite(tx.PaidCurrencyValue)
      ? round3(tx.PaidCurrencyValue)
      : typeof data?.InvoiceValue === "number" &&
          Number.isFinite(data.InvoiceValue)
        ? round3(data.InvoiceValue)
        : null;

  // MyFatoorah occasionally responds with "succss" (sic) — handled defensively.
  const ok =
    isSuccess &&
    (invoiceStatus === "paid" || invoiceStatus === "success") &&
    (txStatus === "" || txStatus === "succss" || txStatus === "success");

  const reference =
    strOrNull(data?.InvoiceReference) ?? strOrNull(tx?.ReferenceId);
  const customerReference = strOrNull(data?.CustomerReference);
  const userDefinedField = strOrNull(data?.UserDefinedField);
  const invoiceIdStr =
    typeof data?.InvoiceId === "number" ? String(data.InvoiceId) : null;

  return {
    ok,
    status: invoiceStatus || txStatus || "unknown",
    amountKwd: amount,
    currency,
    reference,
    customerReference,
    userDefinedField,
    invoiceId: invoiceIdStr,
    raw: json,
  };
}

/**
 * Hard reject obviously-fake payment ids. Real MyFatoorah ids never start
 * with these prefixes; some have appeared in legacy test data.
 */
export function rejectIfMockPaymentId(paymentId: string): void {
  const p = paymentId.trim().toLowerCase();
  if (
    p.startsWith("fake_") ||
    p.startsWith("mock_") ||
    p.startsWith("simulate_")
  ) {
    throw new HttpsError("failed-precondition", "Invalid paymentId");
  }
}
