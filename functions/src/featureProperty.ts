import * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

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

/**
 * Callable: featureProperty
 *
 * Securely sets/extends `properties/{propertyId}.featuredUntil` for the owner.
 * - Auth required
 * - Must be the property owner
 * - Server-only write via Admin SDK (Firestore rules block client writes)
 *
 * Input:
 * - propertyId: string
 * - durationDays: number
 */
export const featureProperty = onCall({ region: "us-central1" }, async (request) => {
  const uid = requireUid(request);
  const data = (request.data ?? {}) as Record<string, unknown>;

  const propertyId = typeof data.propertyId === "string" ? data.propertyId.trim() : "";
  if (!propertyId) {
    throw new HttpsError("invalid-argument", "propertyId is required");
  }

  const durationDaysRaw = toFiniteNumber(data.durationDays, NaN);
  if (!Number.isFinite(durationDaysRaw)) {
    throw new HttpsError("invalid-argument", "durationDays is required");
  }
  const durationDays = Math.floor(durationDaysRaw);
  if (durationDays <= 0) {
    throw new HttpsError("invalid-argument", "durationDays must be > 0");
  }
  // Safety cap: prevents accidental huge timestamps (and future abuse if pricing isn't wired yet).
  if (durationDays > 90) {
    throw new HttpsError("invalid-argument", "durationDays too large");
  }

  const ref = db.collection("properties").doc(propertyId);
  const snap = await ref.get();
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

  // TODO(payment): enforce entitlement before featuring (invoice/payment_logs/company_payments).

  const now = new Date();
  const currentRaw = p.featuredUntil;
  const current =
    currentRaw instanceof Timestamp ? currentRaw.toDate() : null;
  const baseDate = current && current.getTime() > now.getTime() ? current : now;
  const newFeaturedUntil = new Date(
    baseDate.getTime() + durationDays * 24 * 60 * 60 * 1000,
  );

  await ref.update({
    featuredUntil: Timestamp.fromDate(newFeaturedUntil),
    updatedAt: FieldValue.serverTimestamp(),
  });

  return {
    success: true,
    newFeaturedUntil: newFeaturedUntil.toISOString(),
    newFeaturedUntilMs: newFeaturedUntil.getTime(),
    durationDays,
    propertyId,
  };
});

