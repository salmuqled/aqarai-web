/**
 * يجمّع نشاط المستخدمين (مع توكن FCM صالح فقط) في `activity_stats/global` كل ساعة.
 */
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue } from "firebase-admin/firestore";

import { isValidFcmTokenString } from "./fcmToken";

export const ACTIVITY_STATS_GLOBAL = "activity_stats/global";
const ACTIVITY_LOOKBACK_DAYS = 30;
const MAX_ACTIVITY_DOCS = 25000;

function emptyHourly(): Record<string, number> {
  const h: Record<string, number> = {};
  for (let i = 0; i < 24; i++) {
    h[String(i)] = 0;
  }
  return h;
}

export const updateActivityStats = onSchedule(
  {
    region: "us-central1",
    schedule: "every 60 minutes",
    timeZone: "UTC",
  },
  async () => {
    const db = admin.firestore();
    const now = Date.now();
    const t7 = now - 7 * 24 * 60 * 60 * 1000;
    const t30 = now - ACTIVITY_LOOKBACK_DAYS * 24 * 60 * 60 * 1000;
    const ts30 = admin.firestore.Timestamp.fromMillis(t30);

    const usersSnap = await db
      .collection("users")
      .where("fcmToken", "!=", null)
      .get();

    const fcmUids = new Set<string>();
    for (const d of usersSnap.docs) {
      if (isValidFcmTokenString(d.data().fcmToken)) {
        fcmUids.add(d.id);
      }
    }
    const usersWithFcmTotal = fcmUids.size;

    const activitySnap = await db
      .collection("user_activity")
      .where("lastSeenAt", ">=", ts30)
      .limit(MAX_ACTIVITY_DOCS)
      .get();

    const hourly = emptyHourly();
    let active7d = 0;
    let warm30d = 0;

    for (const doc of activitySnap.docs) {
      const uid = doc.id;
      if (!fcmUids.has(uid)) continue;

      const data = doc.data();
      const ls = data.lastSeenAt as admin.firestore.Timestamp | undefined;
      const ms = ls?.toMillis() ?? 0;

      let h = data.lastActiveHour;
      if (typeof h !== "number" || h < 0 || h > 23) {
        h = -1;
      }
      if (h >= 0 && h <= 23) {
        const key = String(h);
        hourly[key] = (hourly[key] ?? 0) + 1;
      }

      if (ms >= t7) {
        active7d++;
      } else if (ms >= t30) {
        warm30d++;
      }
    }

    const cold = Math.max(0, usersWithFcmTotal - active7d - warm30d);

    await db.doc(ACTIVITY_STATS_GLOBAL).set(
      {
        hourly,
        active7d,
        warm30d,
        cold,
        usersWithFcmTotal,
        activityDocsScanned: activitySnap.size,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }
);
