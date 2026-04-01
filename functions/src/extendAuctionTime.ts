/**
 * Callable (admin): extend `lots/{lotId}.endsAt` by a delta (seconds).
 * newEndsAt = current endsAt + extraSeconds (never replaces with an absolute time).
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { assertAdminClaimAndDirectory } from "./auctionAdminAuth";

const LOTS = "lots";
const LOGS = "auction_logs";
const LOT_ACTIVE = "active";

/** Max single extension (7 days) to limit mistakes / abuse. */
const MAX_EXTRA_SECONDS = 7 * 24 * 60 * 60;

function readTimestamp(v: unknown): Timestamp | null {
  if (v instanceof Timestamp) return v;
  if (v && typeof v === "object" && "toMillis" in v) {
    return v as Timestamp;
  }
  return null;
}

function readLotEndsAt(lot: Record<string, unknown>): Timestamp | null {
  return readTimestamp(lot.endsAt) ?? readTimestamp(lot.endTime);
}

function parseExtraSeconds(raw: unknown): number {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    if (!Number.isInteger(raw)) {
      throw new HttpsError(
        "invalid-argument",
        "extraSeconds must be a whole number"
      );
    }
    return raw;
  }
  if (typeof raw === "string") {
    const n = parseInt(raw, 10);
    if (!Number.isFinite(n) || String(n) !== raw.trim()) {
      throw new HttpsError(
        "invalid-argument",
        "extraSeconds must be a positive integer"
      );
    }
    return n;
  }
  throw new HttpsError("invalid-argument", "extraSeconds is required");
}

export const extendAuctionTime = onCall(
  { region: "us-central1" },
  async (request) => {
    const adminUid = await assertAdminClaimAndDirectory(request);
    const data = request.data as Record<string, unknown> | undefined;
    const lotId =
      typeof data?.lotId === "string" ? data.lotId.trim() : "";
    if (!lotId) {
      throw new HttpsError("invalid-argument", "lotId is required");
    }

    const extraSeconds = parseExtraSeconds(data?.extraSeconds);
    if (extraSeconds <= 0) {
      throw new HttpsError(
        "invalid-argument",
        "extraSeconds must be positive"
      );
    }
    if (extraSeconds > MAX_EXTRA_SECONDS) {
      throw new HttpsError(
        "invalid-argument",
        `extraSeconds cannot exceed ${MAX_EXTRA_SECONDS} (7 days)`
      );
    }

    const db = admin.firestore();
    const lotRef = db.collection(LOTS).doc(lotId);

    const newEndsAtMs = await db.runTransaction(async (t) => {
      const snap = await t.get(lotRef);
      if (!snap.exists || !snap.data()) {
        throw new HttpsError("not-found", "Lot not found");
      }
      const lot = snap.data()!;
      const status = String(lot.status ?? "");
      if (status !== LOT_ACTIVE) {
        throw new HttpsError(
          "failed-precondition",
          "Lot must be active to extend auction time"
        );
      }

      const oldEndsAt = readLotEndsAt(lot);
      if (!oldEndsAt) {
        throw new HttpsError(
          "failed-precondition",
          "Lot endsAt is missing"
        );
      }

      const oldMs = oldEndsAt.toMillis();
      const newMs = oldMs + extraSeconds * 1000;
      const newEndsAt = Timestamp.fromMillis(newMs);
      const now = FieldValue.serverTimestamp();

      t.update(lotRef, {
        endsAt: newEndsAt,
        updatedAt: now,
      });

      const logRef = db.collection(LOGS).doc();
      t.set(logRef, {
        type: "manual_extension",
        adminId: adminUid,
        lotId,
        oldEndsAt,
        newEndsAt,
        timestamp: now,
      });

      return newMs;
    });

    return {
      success: true,
      newEndsAt: newEndsAtMs,
    };
  }
);
