/**
 * Scheduled: multi-stage FCM reminders for lots in `pending_admin_review`
 * before `approvalDeadlineAt` (1h, 10m, 1m).
 *
 * Idempotent flags (one send per stage per lot):
 * - approvalOneHourWarningSent
 * - approvalTenMinWarningSent
 * - approvalOneMinWarningSent
 *
 * Each tick runs at most one new stage per lot (most urgent first: 1m > 10m > 1h)
 * inside a single Firestore transaction, then FCM after commit.
 *
 * Schedule: every 1 minute so the 1-minute window is not skipped.
 *
 * Query (index: lots — status + approvalDeadlineAt):
 * - status == pending_admin_review
 * - approvalDeadlineAt > now
 * - approvalDeadlineAt <= now + 1h
 */
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import type { DocumentData } from "firebase-admin/firestore";
import {
  FieldValue,
  Timestamp,
  type Firestore,
} from "firebase-admin/firestore";

import {
  LOTS,
  LOT_PENDING_ADMIN_REVIEW,
  readTimestamp,
} from "./auctionFinalizeCore";
import { isValidFcmTokenString } from "./fcmToken";

const ADMINS = "admins";
const USERS = "users";
const PROPERTIES = "properties";
const QUERY_LIMIT = 40;

const ONE_HOUR_MS = 60 * 60 * 1000;
const TEN_MIN_MS = 10 * 60 * 1000;
const ONE_MIN_MS = 60 * 1000;

export type ApprovalReminderStage = "1h" | "10m" | "1m";

/** Default title for all stages (short tray title). */
export const APPROVAL_REMINDER_TITLE = "اعتماد الصفقة";

export const APPROVAL_REMINDER_BODY_1H =
  "⏳ باقي أقل من ساعة لاعتماد الصفقة";
export const APPROVAL_REMINDER_BODY_10M =
  "⚠️ باقي 10 دقائق لاعتماد الصفقة";
export const APPROVAL_REMINDER_BODY_1M =
  "🔥 آخر دقيقة لاعتماد الصفقة";

/** Legacy export — same as 1h body. */
export const APPROVAL_PRE_EXPIRY_NOTIFICATION_TITLE = APPROVAL_REMINDER_TITLE;
export const APPROVAL_PRE_EXPIRY_NOTIFICATION_BODY = APPROVAL_REMINDER_BODY_1H;

/** FCM `data.type` per stage (current). */
export const FCM_TYPE_AUCTION_APPROVAL_1H = "auction_approval_1h";
export const FCM_TYPE_AUCTION_APPROVAL_10M = "auction_approval_10m";
export const FCM_TYPE_AUCTION_APPROVAL_1M = "auction_approval_1m";

/**
 * @deprecated Older payloads only; new sends use [FCM_TYPE_AUCTION_APPROVAL_1H] etc.
 */
export const APPROVAL_PRE_EXPIRY_FCM_TYPE = "auction_approval_deadline_soon";

const STAGE_FCM_TYPE: Record<ApprovalReminderStage, string> = {
  "1h": FCM_TYPE_AUCTION_APPROVAL_1H,
  "10m": FCM_TYPE_AUCTION_APPROVAL_10M,
  "1m": FCM_TYPE_AUCTION_APPROVAL_1M,
};

const STAGE_COPY: Record<
  ApprovalReminderStage,
  { title: string; body: string }
> = {
  "1h": { title: APPROVAL_REMINDER_TITLE, body: APPROVAL_REMINDER_BODY_1H },
  "10m": { title: APPROVAL_REMINDER_TITLE, body: APPROVAL_REMINDER_BODY_10M },
  "1m": { title: APPROVAL_REMINDER_TITLE, body: APPROVAL_REMINDER_BODY_1M },
};

/**
 * Pick the single stage to fire this tick: most urgent window first so we never
 * blast 3 notifications if all flags were false at once (e.g. after downtime).
 */
export function pickApprovalReminderStage(
  remainingMs: number,
  lot: DocumentData
): ApprovalReminderStage | null {
  if (remainingMs <= 0) return null;
  if (
    remainingMs <= ONE_MIN_MS &&
    lot.approvalOneMinWarningSent !== true
  ) {
    return "1m";
  }
  if (
    remainingMs <= TEN_MIN_MS &&
    lot.approvalTenMinWarningSent !== true
  ) {
    return "10m";
  }
  if (
    remainingMs <= ONE_HOUR_MS &&
    lot.approvalOneHourWarningSent !== true
  ) {
    return "1h";
  }
  return null;
}

type LotMeta = {
  auctionId: string;
  propertyId: string | null;
  stage: ApprovalReminderStage;
};

async function getActiveAdminUids(db: Firestore): Promise<string[]> {
  const snap = await db.collection(ADMINS).get();
  const out: string[] = [];
  for (const d of snap.docs) {
    if (d.data()?.active === false) continue;
    out.push(d.id);
  }
  return out;
}

async function readFcmToken(db: Firestore, uid: string): Promise<string | null> {
  const snap = await db.collection(USERS).doc(uid).get();
  const raw = snap.data()?.fcmToken;
  if (typeof raw !== "string" || !isValidFcmTokenString(raw)) return null;
  return raw.trim();
}

/**
 * FCM data (strings only): type (auction_approval_1h|10m|1m), lotId, auctionId, role.
 */
async function sendApprovalReminderPush(args: {
  db: Firestore;
  uid: string;
  lotId: string;
  auctionId: string;
  role: "seller" | "admin";
  stage: ApprovalReminderStage;
}): Promise<void> {
  const token = await readFcmToken(args.db, args.uid);
  if (!token) return;

  const copy = STAGE_COPY[args.stage];
  const data: Record<string, string> = {
    type: STAGE_FCM_TYPE[args.stage],
    lotId: args.lotId,
    auctionId: args.auctionId,
    role: args.role,
  };

  try {
    await admin.messaging().send({
      token,
      notification: {
        title: copy.title,
        body: copy.body,
      },
      data,
      android: { priority: "high" },
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    });
  } catch (e: unknown) {
    const code =
      e && typeof e === "object" && "code" in e
        ? String((e as { code?: string }).code)
        : String(e);
    logger.warn("auctionApprovalPreExpiry: FCM failed", {
      uid: args.uid,
      lotId: args.lotId,
      stage: args.stage,
      code,
    });
    if (
      code.includes("registration-token-not-registered") ||
      code.includes("invalid-registration-token")
    ) {
      await args.db
        .collection(USERS)
        .doc(args.uid)
        .update({ fcmToken: FieldValue.delete() })
        .catch(() => undefined);
    }
  }
}

export const notifyAuctionApprovalDeadlineSoon = onSchedule(
  {
    region: "us-central1",
    schedule: "every 1 minutes",
    timeZone: "Asia/Kuwait",
    memory: "256MiB",
  },
  async () => {
    const db = admin.firestore();
    const nowMs = Date.now();
    const now = Timestamp.fromMillis(nowMs);
    const oneHourFromNow = Timestamp.fromMillis(nowMs + ONE_HOUR_MS);

    const snap = await db
      .collection(LOTS)
      .where("status", "==", LOT_PENDING_ADMIN_REVIEW)
      .where("approvalDeadlineAt", ">", now)
      .where("approvalDeadlineAt", "<=", oneHourFromNow)
      .limit(QUERY_LIMIT)
      .get();

    if (snap.empty) return;

    const adminUids = await getActiveAdminUids(db);
    let lotsNotified = 0;
    let pushesAttempted = 0;

    for (const doc of snap.docs) {
      const lotId = doc.id;
      let meta: LotMeta | null = null;

      try {
        meta = await db.runTransaction(async (t): Promise<LotMeta | null> => {
          const s = await t.get(doc.ref);
          if (!s.exists || !s.data()) return null;
          const lot = s.data()!;
          if (String(lot.status ?? "") !== LOT_PENDING_ADMIN_REVIEW) {
            return null;
          }
          const dl = readTimestamp(lot.approvalDeadlineAt);
          if (!dl) return null;
          const dms = dl.toMillis();
          const remainingMs = dms - nowMs;
          if (remainingMs <= 0 || remainingMs > ONE_HOUR_MS) return null;

          const stage = pickApprovalReminderStage(remainingMs, lot);
          if (!stage) return null;

          const auctionId = String(lot.auctionId ?? "");
          const pidRaw = lot.propertyId;
          const propertyId =
            pidRaw != null && String(pidRaw).trim() !== ""
              ? String(pidRaw).trim()
              : null;

          const patch: Record<string, unknown> = {
            updatedAt: FieldValue.serverTimestamp(),
          };
          if (stage === "1h") patch.approvalOneHourWarningSent = true;
          if (stage === "10m") patch.approvalTenMinWarningSent = true;
          if (stage === "1m") patch.approvalOneMinWarningSent = true;

          t.update(doc.ref, patch);

          return { auctionId, propertyId, stage };
        });
      } catch (e) {
        logger.warn("auctionApprovalPreExpiry: transaction failed", {
          lotId,
          error: e instanceof Error ? e.message : String(e),
        });
        continue;
      }

      if (!meta) continue;
      lotsNotified++;

      const recipientUids = new Set<string>();
      for (const a of adminUids) {
        recipientUids.add(a);
      }

      if (meta.propertyId) {
        try {
          const prop = await db
            .collection(PROPERTIES)
            .doc(meta.propertyId)
            .get();
          const owner = prop.data()?.ownerId;
          if (owner != null && String(owner).trim() !== "") {
            recipientUids.add(String(owner).trim());
          }
        } catch (e) {
          logger.warn("auctionApprovalPreExpiry: read property failed", {
            lotId,
            propertyId: meta.propertyId,
            error: e instanceof Error ? e.message : String(e),
          });
        }
      }

      for (const uid of recipientUids) {
        const role: "seller" | "admin" = adminUids.includes(uid)
          ? "admin"
          : "seller";
        pushesAttempted++;
        await sendApprovalReminderPush({
          db,
          uid,
          lotId,
          auctionId: meta.auctionId,
          role,
          stage: meta.stage,
        });
      }
    }

    if (lotsNotified > 0) {
      logger.info("notifyAuctionApprovalDeadlineSoon: done", {
        scanned: snap.size,
        lotsNotified,
        pushesAttempted,
      });
    }
  }
);
