/**
 * FCM helper: throttle → persist notifications/{id} → send push with Android priority/sound.
 * Never throws to callers — logs only; invalid tokens clear `fcmToken` when FCM says so.
 */
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { isValidFcmTokenString } from "./fcmToken";

const db = admin.firestore();

/** FCM `data.notificationType` values (client routing). */
export type UserNotificationType = "booking" | "payout" | "refund";

/** Stored in Firestore `notifications` for analytics / inbox (includes cancel). */
export type PersistedNotificationType = "booking" | "payout" | "refund" | "cancel";

export type SendUserNotificationArgs = {
  uid: string;
  title: string;
  body: string;
  notificationType: UserNotificationType;
  /** Firestore + throttle bucket; defaults to [notificationType]. Use "cancel" for cancel pushes while FCM stays "booking". */
  persistedNotificationType?: PersistedNotificationType;
  /** FCM data map — values must be strings */
  data?: Record<string, string>;
};

const THROTTLE_MS = 5000;

const DEEPLINK_KEYS = [
  "screen",
  "bookingId",
  "propertyId",
  "transactionId",
  "bookingAction",
  "cancelledBy",
] as const;

/** KWD amounts in Arabic notification copy (3 dp max, trim trailing noise). */
export function formatKwdForNotification(n: number): string {
  if (!Number.isFinite(n)) {
    return "—";
  }
  const r = Math.round(n * 1000) / 1000;
  if (Math.abs(r - Math.round(r)) < 1e-9) {
    return String(Math.round(r));
  }
  return String(r);
}

function persistedTypeOf(
  args: SendUserNotificationArgs
): PersistedNotificationType {
  return args.persistedNotificationType ?? args.notificationType;
}

/** Firestore inbox: revenue/booking alerts first; refund/cancel routine. */
function inboxPriorityForPersistedType(
  t: PersistedNotificationType
): "high" | "normal" {
  return t === "booking" || t === "payout" ? "high" : "normal";
}

function extractDeepLinkForStore(
  data?: Record<string, string>
): Record<string, string> {
  if (!data) return {};
  const out: Record<string, string> = {};
  for (const k of DEEPLINK_KEYS) {
    const v = data[k];
    if (typeof v === "string" && v.trim().length > 0) {
      out[k] = v.trim();
    }
  }
  return out;
}

async function shouldThrottle(
  userId: string,
  persistedType: PersistedNotificationType
): Promise<boolean> {
  try {
    const q = await db
      .collection("notifications")
      .where("userId", "==", userId)
      .where("notificationType", "==", persistedType)
      .orderBy("createdAt", "desc")
      .limit(1)
      .get();
    if (q.empty) return false;
    const last = q.docs[0].data().createdAt;
    if (!(last instanceof admin.firestore.Timestamp)) return false;
    return Date.now() - last.toMillis() < THROTTLE_MS;
  } catch (e: unknown) {
    console.warn({
      event: "notification.throttle_check.failed",
      userId,
      type: persistedType,
      error: e instanceof Error ? e.message : String(e),
    });
    return false;
  }
}

/**
 * Merges deep-link fields, adds `createdAt` / `isRead` for FCM data (strings),
 * `notificationId` / `version` after doc write — drops empty optional keys.
 */
function normalizeFcmDataPayload(
  notificationType: UserNotificationType,
  notificationId: string,
  extra?: Record<string, string>
): Record<string, string> {
  const merged: Record<string, string> = {
    notificationType,
    createdAt: new Date().toISOString(),
    isRead: "false",
    ...(extra ?? {}),
    notificationId,
    version: "1",
  };
  const alwaysKeep = new Set([
    "notificationType",
    "createdAt",
    "isRead",
    "notificationId",
    "version",
  ]);
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(merged)) {
    if (v === undefined || v === null) {
      continue;
    }
    if (alwaysKeep.has(k)) {
      out[k] = String(v);
      continue;
    }
    const s = String(v).trim();
    if (s.length === 0) {
      continue;
    }
    out[k] = s;
  }
  return out;
}

export async function sendNotificationToUser(args: SendUserNotificationArgs): Promise<void> {
  const uid = typeof args.uid === "string" ? args.uid.trim() : "";
  if (!uid) {
    return;
  }

  const persistedType = persistedTypeOf(args);

  if (await shouldThrottle(uid, persistedType)) {
    console.info({
      event: "notification.skipped",
      reason: "throttle",
      userId: uid,
      type: persistedType,
      windowMs: THROTTLE_MS,
    });
    return;
  }

  let notificationIdForError: string | undefined;

  try {
    const userSnap = await db.collection("users").doc(uid).get();
    const raw = userSnap.data()?.fcmToken;
    if (!isValidFcmTokenString(raw)) {
      return;
    }
    const token = (raw as string).trim();

    const notificationId = db.collection("notifications").doc().id;
    notificationIdForError = notificationId;
    const dataForStore = extractDeepLinkForStore(args.data);
    const dataPayload = normalizeFcmDataPayload(
      args.notificationType,
      notificationId,
      args.data
    );

    const androidPriority: "high" | "normal" =
      persistedType === "refund" ? "normal" : "high";

    await admin.messaging().send({
      token,
      notification: {
        title: args.title,
        body: args.body,
      },
      data: dataPayload,
      android: {
        priority: androidPriority,
        notification: {
          sound: "default",
        },
      },
    });

    try {
      await db.collection("notifications").doc(notificationId).set({
        userId: uid,
        title: args.title,
        body: args.body,
        notificationType: persistedType,
        priority: inboxPriorityForPersistedType(persistedType),
        isRead: false,
        isHidden: false,
        createdAt: FieldValue.serverTimestamp(),
        data: dataForStore,
        version: 1,
      });
    } catch (persistErr: unknown) {
      console.warn({
        event: "notification.inbox_persist_failed",
        notificationId,
        userId: uid,
        type: persistedType,
        error:
          persistErr instanceof Error ? persistErr.message : String(persistErr),
      });
    }

    console.info({
      event: "notification.sent",
      userId: uid,
      type: persistedType,
      notificationId,
      success: true,
    });
  } catch (e: unknown) {
    const err = e as { code?: string; message?: string };
    const code = String(err?.code ?? "");
    const msg = err?.message ?? String(e);
    if (
      code.includes("registration-token-not-registered") ||
      code.includes("invalid-registration-token")
    ) {
      await db
        .collection("users")
        .doc(uid)
        .update({ fcmToken: FieldValue.delete() })
        .catch(() => undefined);
    }
    console.warn({
      event: "notification.failed",
      userId: uid,
      type: persistedType,
      notificationId: notificationIdForError ?? null,
      errorCode: code || null,
      error: msg,
    });
  }
}
