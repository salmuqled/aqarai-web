import { defineSecret } from "firebase-functions/params";
import { HttpsError } from "firebase-functions/v2/https";

/**
 * Single source of truth for the MyFatoorah API token.
 *
 * - Sandbox: set this secret to MyFatoorah's public test token
 *   `SK_KWT_vVZlnnAqu8jRByOWaRPNId4ShzEDNt256dvnjebuyzo52dXjAfRx2ixW5umjWSUx`
 *   while `MYFATOORAH_API_BASE_URL=https://apitest.myfatoorah.com` is set.
 * - Production: rotate to your live merchant token AND flip
 *   `MYFATOORAH_API_BASE_URL` to the country-specific live endpoint
 *   (https://api.myfatoorah.com for KW/BH/JO/OM, https://api-ae.myfatoorah.com
 *   for UAE, etc.). The same secret param + env switch works for both.
 *
 * Every callable that touches MyFatoorah MUST attach this secret via
 * `secrets: [myFatoorahApiKey]` on its `onCall`/`onRequest` definition,
 * otherwise `process.env.MYFATOORAH_API_KEY` is empty in v2 functions.
 */
export const myFatoorahApiKey = defineSecret("MYFATOORAH_API_KEY");

/** Returns the configured base URL (defaults to the SANDBOX while we are in test mode). */
export function myFatoorahBaseUrl(): string {
  return (
    process.env.MYFATOORAH_API_BASE_URL ?? "https://apitest.myfatoorah.com"
  )
    .trim()
    .replace(/\/+$/, "");
}

/**
 * Public HTTPS endpoint for [ExecutePayment] callbacks. MyFatoorah rejects
 * custom schemes ([aqarai://]) for CallBackUrl/ErrorUrl; the app is opened via
 * a short HTML+JS handoff from [myFatoorahAppReturn].
 *
 * Set `MYFATOORAH_APP_RETURN_BASE` if you use a custom domain or re-point the
 * function; must be https and without a trailing slash.
 */
export function myFatoorahAppReturnBaseUrl(): string {
  return (
    process.env.MYFATOORAH_APP_RETURN_BASE?.trim() ??
    "https://us-central1-aqarai-caf5d.cloudfunctions.net/myFatoorahAppReturn"
  )
    .replace(/\/+$/, "");
}

export function isPaymentEnabled(): boolean {
  const key = process.env.MYFATOORAH_API_KEY;
  if (!key) return false;
  const t = String(key).trim();
  return t.length > 0 && t !== "test_key";
}

export function requirePaymentEnabledOrExplain(): void {
  if (isPaymentEnabled()) return;
  console.warn(
    "[payments] MyFatoorah disabled: missing MYFATOORAH_API_KEY or set to test_key"
  );
  throw new HttpsError(
    "failed-precondition",
    "Payment system not configured yet"
  );
}
