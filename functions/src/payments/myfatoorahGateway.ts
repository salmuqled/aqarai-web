/**
 * Shared MyFatoorah gateway helpers (InitiatePayment + ExecutePayment).
 *
 * Used by every server callable that has to mint a hosted payment URL:
 *   - bookings (chalet_booking_payment_myfatoorah.ts has its own copy for now)
 *   - auction listing fees (createAuctionFeeMyFatoorahPayment)
 *   - featured ad payments (createFeaturePropertyMyFatoorahPayment)
 *
 * NEVER import this on the client. The API token (`MYFATOORAH_API_KEY`) is
 * a Secret Manager secret bound only to backend functions.
 */
import { HttpsError } from "firebase-functions/v2/https";

import {
  myFatoorahBaseUrl,
  requirePaymentEnabledOrExplain,
} from "./myfatoorahRuntime";

type InitiatePaymentResponse = {
  IsSuccess?: boolean;
  Message?: string;
  Data?: {
    PaymentMethods?: Array<{
      PaymentMethodId?: number;
      /** Includes service charge; intended for [ExecutePayment.InvoiceValue]. */
      TotalAmount?: number;
      PaymentMethodEn?: string;
      PaymentMethodAr?: string;
      IsDirectPayment?: boolean;
    }>;
  };
};

export type ExecutePaymentResponse = {
  IsSuccess?: boolean;
  Message?: string;
  /** Present when a field fails gateway validation. */
  ValidationErrors?: unknown;
  Data?: {
    InvoiceId?: number;
    PaymentURL?: string;
    PaymentId?: string | number;
    [key: string]: unknown;
  };
};

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

/** Some portal versions omit [Data.PaymentId]; the hosted [PaymentURL] may carry an id. */
function tryPaymentIdFromPaymentUrl(paymentUrl: string): string | null {
  try {
    const u = new URL(paymentUrl);
    for (const k of [
      "paymentId",
      "PaymentId",
      "id",
      "Id",
      "paymentid",
    ]) {
      const v = u.searchParams.get(k);
      if (v && v.trim().length > 0) {
        return v.trim();
      }
    }
  } catch {
    return null;
  }
  return null;
}

function parseExecutePaymentIdFromData(
  data: Record<string, unknown> | undefined
): string {
  if (!data) {
    return "";
  }
  const raw =
    data.PaymentId ??
    data.paymentId ??
    (data as { PaymentID?: unknown }).PaymentID;
  if (typeof raw === "string" && raw.trim().length > 0) {
    return raw.trim();
  }
  if (typeof raw === "number" && Number.isFinite(raw)) {
    return String(raw);
  }
  return "";
}

/**
 * Parses a successful [ExecutePayment] body. Some MyFatoorah responses omit
 * [Data.PaymentId]; we then use [inv:<InvoiceId>] for [GetPaymentStatus].
 */
export function resolveExecutePaymentSessionIds(
  responseBodyText: string,
  json: ExecutePaymentResponse
): ExecutePaymentResult {
  const root = json as Record<string, unknown>;
  const dataRaw = (root.Data ?? root.data) as Record<string, unknown> | undefined;

  const paymentUrl =
    typeof dataRaw?.PaymentURL === "string"
      ? dataRaw.PaymentURL.trim()
      : typeof dataRaw?.paymentUrl === "string"
        ? dataRaw.paymentUrl.trim()
        : "";

  let paymentId = parseExecutePaymentIdFromData(dataRaw);
  if (!paymentId && paymentUrl) {
    paymentId = tryPaymentIdFromPaymentUrl(paymentUrl) ?? "";
  }
  const invNum = dataRaw?.InvoiceId;
  const invoiceId =
    typeof invNum === "number" && Number.isFinite(invNum)
      ? String(invNum)
      : null;
  if (!paymentId && invoiceId) {
    paymentId = `inv:${invoiceId}`;
    console.log(
      JSON.stringify({
        tag: "myfatoorah_execute_payment_id_from_invoice",
        invoiceId: invoiceId,
      })
    );
  } else if (!paymentId) {
    console.error(
      JSON.stringify({
        tag: "myfatoorah_execute_missing_both_ids",
        body: responseBodyText.slice(0, 2500),
      })
    );
  }

  if (!paymentUrl) {
    throw new HttpsError("failed-precondition", "Missing PaymentURL");
  }
  if (!paymentId) {
    throw new HttpsError("failed-precondition", "Missing PaymentId");
  }

  return { paymentUrl, paymentId, invoiceId };
}

/**
 * MyFatoorah often returns "Invalid data" when `CustomerReference` /
 * `UserDefinedField` contain punctuation (e.g. `:`) or exceed length limits.
 * Keep [A-Za-z0-9] only; max 50 per common gateway rules.
 */
export function myFatoorahSafeReferenceSegment(raw: string, maxLen = 50): string {
  const t = String(raw).replace(/[^a-zA-Z0-9]/g, "").slice(0, maxLen);
  return t.length > 0 ? t : "aqarai";
}

/**
 * Calls MyFatoorah `InitiatePayment` and returns the first available
 * `PaymentMethodId`. The hosted gateway page MyFatoorah serves us with
 * `ExecutePayment` will list every enabled method anyway, but the API
 * still requires us to pick a default to scope service-charge calculation.
 */
/**
 * Returns the first enabled [PaymentMethodId] for [InitiatePayment].
 * [ExecutePayment.InvoiceValue] must use the same amount as this call's
 * [InvoiceAmount] (see the working chalet flow in chalet_booking_payment_myfatoorah.ts).
 */
export async function myFatoorahInitiatePayment(
  amountKwd: number
): Promise<number> {
  requirePaymentEnabledOrExplain();

  const apiKey = process.env.MYFATOORAH_API_KEY!;
  const url = `${myFatoorahBaseUrl()}/v2/InitiatePayment`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey.trim()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      InvoiceAmount: round3(amountKwd),
      CurrencyIso: "KWD",
    }),
  });
  const text = await res.text();
  let json: InitiatePaymentResponse;
  try {
    json = JSON.parse(text) as InitiatePaymentResponse;
  } catch {
    throw new HttpsError(
      "internal",
      `MyFatoorah invalid JSON (http ${res.status})`
    );
  }
  if (!res.ok || json.IsSuccess !== true) {
    const msg = json?.Message ? String(json.Message) : `http_${res.status}`;
    console.error(
      JSON.stringify({ tag: "myfatoorah_initiate_failed", status: res.status, body: text.slice(0, 2000) })
    );
    throw new HttpsError("failed-precondition", `MyFatoorah error: ${msg}`);
  }
  const methods = json.Data?.PaymentMethods ?? [];
  const first =
    methods.find((m) => typeof m.PaymentMethodId === "number") ?? methods[0];
  const id = first?.PaymentMethodId;
  if (typeof id !== "number" || !Number.isFinite(id)) {
    throw new HttpsError(
      "failed-precondition",
      "MyFatoorah: no payment methods enabled on the portal"
    );
  }
  return id;
}

export interface ExecutePaymentArgs {
  /** Fallback if [invoiceValue] is omitted. */
  amountKwd: number;
  /**
   * Defaults to [amountKwd]. Must match [InitiatePayment] [InvoiceAmount] for
   * the same order (chalet and MF samples use the same value here).
   */
  invoiceValue?: number;
  paymentMethodId: number;
  /** `CustomerReference` (alphanumeric). */
  reference: string;
  callbackUrl: string;
  errorUrl: string;
  language: "AR" | "EN";
}

export interface ExecutePaymentResult {
  paymentUrl: string;
  paymentId: string;
  invoiceId: string | null;
}

/**
 * Calls `ExecutePayment` to create a hosted-payment-page session and returns
 * the URL (open in a WebView), the gateway `PaymentId` (use as the idempotency
 * key + verification target), and the `InvoiceId` if available.
 */
export async function myFatoorahExecutePayment(
  args: ExecutePaymentArgs
): Promise<ExecutePaymentResult> {
  requirePaymentEnabledOrExplain();

  const apiKey = process.env.MYFATOORAH_API_KEY!;
  const inv = round3(args.invoiceValue ?? args.amountKwd);
  // Match the proven chalet flow: [Language] is "AR" | "EN" (not lowercase).
  const url = `${myFatoorahBaseUrl()}/v2/ExecutePayment`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey.trim()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      PaymentMethodId: args.paymentMethodId,
      InvoiceValue: inv,
      CallBackUrl: args.callbackUrl,
      ErrorUrl: args.errorUrl,
      CustomerReference: args.reference,
      Language: args.language,
      DisplayCurrencyIso: "KWD",
    }),
  });

  const text = await res.text();
  let json: ExecutePaymentResponse;
  try {
    json = JSON.parse(text) as ExecutePaymentResponse;
  } catch {
    throw new HttpsError(
      "internal",
      `MyFatoorah invalid JSON (http ${res.status})`
    );
  }
  if (!res.ok || json.IsSuccess !== true) {
    const msg = json?.Message ? String(json.Message) : `http_${res.status}`;
    const verr = json.ValidationErrors;
    console.error(
      JSON.stringify({
        tag: "myfatoorah_execute_failed",
        status: res.status,
        message: msg,
        validationErrors: verr,
        body: text.slice(0, 2000),
      })
    );
    const vtxt =
      verr !== undefined && verr !== null
        ? ` ${JSON.stringify(verr).slice(0, 500)}`
        : "";
    throw new HttpsError(
      "failed-precondition",
      `MyFatoorah error: ${msg}${vtxt}`
    );
  }

  return resolveExecutePaymentSessionIds(text, json);
}
