/**
 * Follow-up FCM for admins when a deal's nextFollowUpAt is overdue.
 *
 * - Scheduled job: query due deals, skip if followUpNotified, send once, set followUpNotified.
 * - Firestore trigger: when nextFollowUpAt changes, reset followUpNotified so a new overdue
 *   window can notify again.
 */
import * as admin from "firebase-admin";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

import { isValidFcmTokenString } from "./fcmToken";

const DEALS = "deals";
const ADMINS = "admins";
const USERS = "users";
const FOLLOWUP_LOG = "followup_notifications";

const DEAL_STATUS_CLOSED = "closed";
const DEAL_STATUS_NOT_INTERESTED = "not_interested";

/** Visible in notification body / data; empty → "Property" */
const PROPERTY_TITLE_MAX_LEN = 120;

const TITLE_FOLLOW_UP = "Follow-up required";
const TITLE_FOLLOW_UP_URGENT = "⚠️ Urgent follow-up required";

const QUERY_LIMIT = 400;
const FCM_CHUNK = 500;

async function getActiveAdminUids(db: Firestore): Promise<string[]> {
  const snap = await db.collection(ADMINS).get();
  const out: string[] = [];
  for (const d of snap.docs) {
    if (d.data()?.active === false) continue;
    out.push(d.id);
  }
  return out;
}

async function collectAdminFcmTokens(db: Firestore): Promise<string[]> {
  const uids = await getActiveAdminUids(db);
  const tokens: string[] = [];
  const seen = new Set<string>();
  for (const uid of uids) {
    const snap = await db.collection(USERS).doc(uid).get();
    const raw = snap.data()?.fcmToken;
    if (typeof raw !== "string" || !isValidFcmTokenString(raw)) continue;
    const t = raw.trim();
    if (seen.has(t)) continue;
    seen.add(t);
    tokens.push(t);
  }
  return tokens;
}

function dealIsOverdueAndActionable(data: Record<string, unknown>): boolean {
  const st = String(data.dealStatus ?? "").trim();
  if (st === DEAL_STATUS_CLOSED || st === DEAL_STATUS_NOT_INTERESTED) {
    return false;
  }
  const n = data.nextFollowUpAt;
  if (!(n instanceof Timestamp)) return false;
  return n.toMillis() < Date.now();
}

function followUpAtMillis(data: Record<string, unknown> | undefined): number | undefined {
  const v = data?.nextFollowUpAt;
  return v instanceof Timestamp ? v.toMillis() : undefined;
}

/** Trim, cap length, fallback "Property" (for data payload & notification copy). */
function safePropertyTitle(raw: unknown): string {
  const t = String(raw ?? "").trim();
  if (!t) return "Property";
  if (t.length <= PROPERTY_TITLE_MAX_LEN) return t;
  return `${t.slice(0, PROPERTY_TITLE_MAX_LEN)}…`;
}

/** True when follow-up time is strictly before now (urgent path for title). */
function isFollowUpOverdueNow(data: Record<string, unknown>): boolean {
  const n = data.nextFollowUpAt;
  if (!(n instanceof Timestamp)) return false;
  return n.toMillis() < Date.now();
}

async function sendFollowUpMulticast(
  tokens: string[],
  dealId: string,
  deal: Record<string, unknown>
): Promise<number> {
  if (tokens.length === 0) return 0;
  const messaging = admin.messaging();

  const propertyTitle = safePropertyTitle(deal.propertyTitle);
  const titleForBody = propertyTitle.replace(/"/g, "'");
  const body = `Lead for "${titleForBody}" needs follow-up now`;

  const urgent = isFollowUpOverdueNow(deal);
  const notificationTitle = urgent ? TITLE_FOLLOW_UP_URGENT : TITLE_FOLLOW_UP;

  const dataPayload: Record<string, string> = {
    type: "deal_followup",
    dealId,
    propertyTitle,
  };

  let success = 0;
  for (let i = 0; i < tokens.length; i += FCM_CHUNK) {
    const chunk = tokens.slice(i, i + FCM_CHUNK);
    const res = await messaging.sendEachForMulticast({
      tokens: chunk,
      notification: {
        title: notificationTitle,
        body,
      },
      data: dataPayload,
      android: { priority: "high" },
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    });
    success += res.successCount;
    for (let j = 0; j < res.responses.length; j++) {
      const r = res.responses[j]!;
      if (r.success) continue;
      const code = String(r.error?.code ?? r.error ?? "");
      logger.warn("dealFollowUpReminders FCM failure", { dealId, code });
    }
  }
  return success;
}

/** Hourly: overdue deals → one FCM burst per overdue period (followUpNotified). */
export const dispatchDealFollowUpReminders = onSchedule(
  {
    region: "us-central1",
    schedule: "every 60 minutes",
    timeZone: "Asia/Kuwait",
    memory: "256MiB",
  },
  async () => {
    const db = admin.firestore();
    const now = Timestamp.now();

    let snap;
    try {
      snap = await db
        .collection(DEALS)
        .where("nextFollowUpAt", "<=", now)
        .orderBy("nextFollowUpAt", "asc")
        .limit(QUERY_LIMIT)
        .get();
    } catch (e) {
      logger.error("dealFollowUpReminders query failed", e);
      return;
    }

    if (snap.empty) return;

    const tokens = await collectAdminFcmTokens(db);
    if (tokens.length === 0) {
      logger.warn("dealFollowUpReminders: no admin FCM tokens");
    }

    let dealsChecked = 0;
    let pushes = 0;
    let flagged = 0;
    let logsWritten = 0;

    for (const doc of snap.docs) {
      const dealId = doc.id;
      const data = doc.data() as Record<string, unknown>;

      if (!dealIsOverdueAndActionable(data)) continue;

      if (data.followUpNotified === true) continue;

      dealsChecked++;

      const sent = await sendFollowUpMulticast(tokens, dealId, data);
      pushes += sent;

      if (sent > 0) {
        await doc.ref.update({
          followUpNotified: true,
          updatedAt: FieldValue.serverTimestamp(),
        });
        flagged++;

        await db.collection(FOLLOWUP_LOG).add({
          dealId,
          sentAt: FieldValue.serverTimestamp(),
        });
        logsWritten++;
      }
    }

    logger.info("dealFollowUpReminders done", {
      dealsChecked,
      pushes,
      dealsFlagged: flagged,
      logsWritten,
      adminTokens: tokens.length,
    });
  }
);

/** When nextFollowUpAt changes, allow a new overdue notification for the next window. */
export const resetDealFollowUpNotifiedOnNextAtChange = onDocumentUpdated(
  {
    document: `${DEALS}/{dealId}`,
    region: "us-central1",
  },
  async (event) => {
    const before = event.data?.before.data() as Record<string, unknown> | undefined;
    const after = event.data?.after.data() as Record<string, unknown> | undefined;
    if (!before || !after) return;

    const bm = followUpAtMillis(before);
    const am = followUpAtMillis(after);
    if (bm === am) return;

    await event.data!.after.ref.update({
      followUpNotified: false,
      updatedAt: FieldValue.serverTimestamp(),
    });

    logger.info("reset followUpNotified (nextFollowUpAt changed)", {
      dealId: event.params.dealId,
    });
  }
);
