import * as admin from "firebase-admin";

import { isValidFcmTokenString } from "./fcmToken";

/**
 * Returns a set of user IDs to target, or null = all users with tokens (no filter).
 * Only includes users with a valid FCM token. Activity query is bounded to last 30 days.
 */
export async function audienceUidFilter(
  rawSegment: unknown
): Promise<Set<string> | null> {
  const seg =
    typeof rawSegment === "string" ? rawSegment.trim().toLowerCase() : "all";
  if (seg === "" || seg === "all") return null;

  const db = admin.firestore();
  const nowMs = Date.now();
  const t7 = nowMs - 7 * 24 * 60 * 60 * 1000;
  const t30 = nowMs - 30 * 24 * 60 * 60 * 1000;
  const ts30 = admin.firestore.Timestamp.fromMillis(t30);

  const [actSnap, usersSnap] = await Promise.all([
    db
      .collection("user_activity")
      .where("lastSeenAt", ">=", ts30)
      .limit(30000)
      .get(),
    db.collection("users").where("fcmToken", "!=", null).get(),
  ]);

  const fcmUids = new Set<string>();
  for (const d of usersSnap.docs) {
    if (isValidFcmTokenString(d.data().fcmToken)) {
      fcmUids.add(d.id);
    }
  }

  const uidActive = new Set<string>();
  const uidWarm = new Set<string>();

  for (const doc of actSnap.docs) {
    if (!fcmUids.has(doc.id)) continue;
    const ls = doc.data().lastSeenAt as admin.firestore.Timestamp | undefined;
    const ms = ls?.toMillis() ?? 0;
    if (ms >= t7) {
      uidActive.add(doc.id);
    } else if (ms >= t30) {
      uidWarm.add(doc.id);
    }
  }

  if (seg === "active") return uidActive;
  if (seg === "warm") return uidWarm;
  if (seg === "cold") {
    const cold = new Set<string>();
    for (const id of fcmUids) {
      if (!uidActive.has(id) && !uidWarm.has(id)) {
        cold.add(id);
      }
    }
    return cold;
  }
  return null;
}
