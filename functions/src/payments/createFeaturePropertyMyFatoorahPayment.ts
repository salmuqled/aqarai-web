/**
 * Callable: createFeaturePropertyMyFatoorahPayment
 *
 * Creates a hosted-payment-page session for "feature my ad" purchases. The
 * server picks the canonical plan for the (`durationDays`, `amountKwd`) pair
 * and rejects anything that doesn't match `FEATURE_PLANS` so a client cannot
 * inflate the price client-side.
 *
 *   client → createFeaturePropertyMyFatoorahPayment({ propertyId, durationDays, amountKwd })
 *          → MyFatoorah hosted page (in-app WebView)
 *          → user pays
 *          → app extracts paymentId → featurePropertyPaid(...)
 *
 * The `myFatoorahWebhook` server-to-server callback is the safety net that
 * ensures `featuredUntil` is updated even if the user never returns to the app.
 */
import * as admin from "firebase-admin";
import { HttpsError, onCall } from "firebase-functions/v2/https";

import {
  myFatoorahExecutePayment,
  myFatoorahInitiatePayment,
  myFatoorahSafeReferenceSegment,
} from "./myfatoorahGateway";
import { myFatoorahApiKey, myFatoorahAppReturnBaseUrl } from "./myfatoorahRuntime";
import { featurePlanFor } from "./pricing";

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

export const createFeaturePropertyMyFatoorahPayment = onCall(
  { region: "us-central1", secrets: [myFatoorahApiKey] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid || typeof uid !== "string" || uid.trim().length === 0) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }

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

    const plan = featurePlanFor(durationDays, amountKwd);
    if (!plan) {
      throw new HttpsError(
        "invalid-argument",
        "Invalid plan (durationDays / amountKwd not in FEATURE_PLANS)"
      );
    }

    const langRaw =
      typeof data.lang === "string" ? data.lang.trim().toLowerCase() : "ar";
    const language: "AR" | "EN" = langRaw.startsWith("en") ? "EN" : "AR";

    const db = admin.firestore();
    const propRef = db.collection("properties").doc(propertyId);
    const snap = await propRef.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Property not found");
    }
    const ownerId = String((snap.data() ?? {}).ownerId ?? "").trim();
    if (!ownerId) {
      throw new HttpsError(
        "failed-precondition",
        "Property ownerId is missing"
      );
    }
    if (ownerId !== uid) {
      throw new HttpsError("permission-denied", "Not your property");
    }

    const paymentMethodId = await myFatoorahInitiatePayment(plan.priceKwd);
    // F + propertyId + durationDays — alphanumeric only (no ':') for MyFatoorah refs.
    const gatewayRef = myFatoorahSafeReferenceSegment(
      `F${propertyId}${String(plan.durationDays)}`
    );
    const appReturn = myFatoorahAppReturnBaseUrl();
    const okQs = new URLSearchParams({
      s: "payment/feature/success",
      propertyId,
      durationDays: String(plan.durationDays),
    });
    const errQs = new URLSearchParams({
      s: "payment/feature/error",
      propertyId,
    });
    const { paymentUrl, paymentId, invoiceId } = await myFatoorahExecutePayment(
      {
        amountKwd: plan.priceKwd,
        paymentMethodId,
        reference: gatewayRef,
        callbackUrl: `${appReturn}?${okQs.toString()}`,
        errorUrl: `${appReturn}?${errQs.toString()}`,
        language,
      }
    );

    return {
      ok: true,
      propertyId,
      paymentUrl,
      paymentId,
      invoiceId,
      durationDays: plan.durationDays,
      amountKwd: plan.priceKwd,
    };
  }
);
