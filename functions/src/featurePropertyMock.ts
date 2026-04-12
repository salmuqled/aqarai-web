import * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

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

/**
 * Callable: featurePropertyMock
 *
 * Development-only mock path:
 * - No secrets
 * - No MyFatoorah API calls
 * - Accepts only paymentId starting with "fake_"
 * - Validates plan + replay protection
 * - Updates `featuredUntil`
 * - Logs to `payment_logs` with paymentMode="mock"
 */
export const featurePropertyMock = onCall(
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
      throw new HttpsError(
        "invalid-argument",
        "durationDays and amountKwd are required",
      );
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
    if (!paymentId.startsWith("fake_")) {
      throw new HttpsError(
        "failed-precondition",
        "Mock mode requires fake_ paymentId",
      );
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

    const now = new Date();
    const currentRaw = p.featuredUntil;
    const current = currentRaw instanceof Timestamp ? currentRaw.toDate() : null;
    const baseDate =
      current && current.getTime() > now.getTime() ? current : now;
    const newFeaturedUntil = new Date(
      baseDate.getTime() + durationDays * 24 * 60 * 60 * 1000,
    );

    const batch = db.batch();

    batch.update(propRef, {
      featuredUntil: Timestamp.fromDate(newFeaturedUntil),
      updatedAt: FieldValue.serverTimestamp(),
    });

    const logRef = db.collection("payment_logs").doc();
    batch.set(logRef, {
      paymentId,
      action: "featured_ad_payment",
      newStatus: "success",
      performedBy: uid,
      timestamp: FieldValue.serverTimestamp(),
      verified: true,
      gateway: "Mock",
      paymentMode: "mock",
      propertyId,
      durationDays,
      amountKwd,
      currency: "KWD",
      gatewayReference: paymentId,
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
  },
);

