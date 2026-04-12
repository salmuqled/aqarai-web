import { HttpsError } from "firebase-functions/v2/https";

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

