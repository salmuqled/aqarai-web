/**
 * جدولة إرسال إشعار عام (موافقة الأدمن) + دفع دوري للوظائف المستحقة.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue, type DocumentReference } from "firebase-admin/firestore";

import { audienceUidFilter } from "./notificationAudience";
import { isValidFcmTokenString } from "./fcmToken";

const FCM_MULTICAST_LIMIT = 500;
const MAX_TITLE = 200;
const MAX_BODY = 500;
const MAX_SOURCE_LEN = 120;
const JOBS = "scheduled_notification_jobs";

function assertAdmin(request: {
  auth?: { uid: string; token: Record<string, unknown> };
}) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required");
  }
  if (request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
  return request.auth.uid;
}

function parseSource(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const s = raw.trim();
  if (s.length === 0) return null;
  return s.length > MAX_SOURCE_LEN ? s.slice(0, MAX_SOURCE_LEN) : s;
}

async function sendMulticastWithCleanup(args: {
  tokens: string[];
  tokenToUid: Map<string, string>;
  title: string;
  body: string;
  data: Record<string, string>;
}): Promise<number> {
  let sent = 0;
  const { tokens, tokenToUid, title, body, data } = args;
  for (let i = 0; i < tokens.length; i += FCM_MULTICAST_LIMIT) {
    const chunk = tokens.slice(i, i + FCM_MULTICAST_LIMIT);
    const response = await admin.messaging().sendEachForMulticast({
      tokens: chunk,
      notification: { title, body },
      data,
    });
    sent += response.successCount;

    const cleanup: Promise<unknown>[] = [];
    response.responses.forEach((res, idx) => {
      if (res.success) return;
      const code = res.error?.code ?? "";
      if (
        code.includes("registration-token-not-registered") ||
        code.includes("invalid-registration-token")
      ) {
        const registrationToken = chunk[idx];
        const uid = tokenToUid.get(registrationToken);
        if (uid) {
          cleanup.push(
            admin
              .firestore()
              .collection("users")
              .doc(uid)
              .update({ fcmToken: FieldValue.delete() })
              .catch(() => undefined)
          );
        }
      }
    });
    await Promise.all(cleanup);
  }
  return sent;
}

async function writeScheduledLog(args: {
  notificationId: string;
  title: string;
  body: string;
  sentCount: number;
  source: string | null;
  predictedScore: number | null;
  variantId: string | null;
}): Promise<void> {
  const db = admin.firestore();
  const batch = db.batch();
  const logRef = db.collection("notification_logs").doc(args.notificationId);
  const text = `${args.title}\n${args.body}`;
  const factors = {
    hasEmoji: false,
    hasArea: false,
    hasUrgency: false,
    shortText: text.length > 0 && text.length <= 160,
  };
  const logPayload: Record<string, unknown> = {
    title: args.title,
    body: args.body,
    type: "broadcast",
    sentCount: args.sentCount,
    clickCount: 0,
    actualCTR: 0,
    conversionCount: 0,
    conversionRate: 0,
    conversionValue: 0,
    factors,
    createdAt: FieldValue.serverTimestamp(),
  };
  if (args.source) logPayload.source = args.source;
  if (args.predictedScore != null) {
    logPayload.predictedScore = args.predictedScore;
  }
  if (args.variantId != null && args.variantId.length > 0) {
    logPayload.variantId = args.variantId;
  }
  batch.set(logRef, logPayload);

  const totRef = db.collection("analytics").doc("notification_totals");
  batch.set(
    totRef,
    {
      totalSent: FieldValue.increment(args.sentCount),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  await batch.commit();
}

/**
 * يُستدعى فقط بعد نجاح معاملة تعيين الحالة إلى `processing` (لا يعيد قراءة `pending`).
 */
async function deliverClaimedJob(
  ref: DocumentReference,
  d: Record<string, unknown>
): Promise<void> {
  const db = admin.firestore();

  const title = typeof d.title === "string" ? d.title.trim() : "";
  const body = typeof d.body === "string" ? d.body.trim() : "";
  if (title.length === 0 || body.length === 0) {
    await ref.update({
      status: "failed",
      failedAt: FieldValue.serverTimestamp(),
      error: "missing_title_or_body",
    });
    return;
  }

  const notificationId =
    typeof d.notificationId === "string" && d.notificationId.length > 0
      ? d.notificationId
      : db.collection("notification_logs").doc().id;

  const uidFilter = await audienceUidFilter(d.audienceSegment);
  const usersSnap = await db
    .collection("users")
    .where("fcmToken", "!=", null)
    .get();
  const tokenToUid = new Map<string, string>();
  const tokens: string[] = [];

  for (const doc of usersSnap.docs) {
    if (uidFilter !== null && !uidFilter.has(doc.id)) continue;
    const raw = doc.data()?.fcmToken;
    if (!isValidFcmTokenString(raw)) continue;
    const tok = (raw as string).trim();
    if (tokenToUid.has(tok)) continue;
    tokenToUid.set(tok, doc.id);
    tokens.push(tok);
  }

  const source = parseSource(d.source);
  let predictedScore: number | null = null;
  let variantId: string | null = null;
  const pm = d.predictionMeta;
  if (pm && typeof pm === "object") {
    const o = pm as Record<string, unknown>;
    if (typeof o.predictedScore === "number" && !Number.isNaN(o.predictedScore)) {
      predictedScore = o.predictedScore;
    }
    if (typeof o.variantId === "string" && o.variantId.trim().length > 0) {
      variantId = o.variantId.trim().slice(0, 40);
    }
  }

  if (tokens.length === 0) {
    await writeScheduledLog({
      notificationId,
      title,
      body,
      sentCount: 0,
      source,
      predictedScore,
      variantId,
    });
    await ref.update({
      status: "sent",
      sentAt: FieldValue.serverTimestamp(),
      sentCount: 0,
      notificationId,
    });
    return;
  }

  const sentCount = await sendMulticastWithCleanup({
    tokens,
    tokenToUid,
    title,
    body,
    data: { notificationId },
  });

  await writeScheduledLog({
    notificationId,
    title,
    body,
    sentCount,
    source,
    predictedScore,
    variantId,
  });

  await ref.update({
    status: "sent",
    sentAt: FieldValue.serverTimestamp(),
    sentCount,
    notificationId,
  });
}

export const queueScheduledNotification = onCall(
  { region: "us-central1" },
  async (request) => {
    const adminUid = assertAdmin(request);
    const data = (request.data || {}) as Record<string, unknown>;

    const title = data.title;
    const body = data.body;
    if (typeof title !== "string" || title.trim().length === 0) {
      throw new HttpsError("invalid-argument", "title is required");
    }
    if (typeof body !== "string" || body.trim().length === 0) {
      throw new HttpsError("invalid-argument", "body is required");
    }
    const t = title.trim();
    const b = body.trim();
    if (t.length > MAX_TITLE || b.length > MAX_BODY) {
      throw new HttpsError("invalid-argument", "title/body too long");
    }

    const scheduledAtMs = data.scheduledAtMs;
    if (typeof scheduledAtMs !== "number" || Number.isNaN(scheduledAtMs)) {
      throw new HttpsError("invalid-argument", "scheduledAtMs is required");
    }
    const minAhead = Date.now() + 60 * 1000;
    const maxAhead = Date.now() + 30 * 24 * 60 * 60 * 1000;
    if (scheduledAtMs < minAhead || scheduledAtMs > maxAhead) {
      throw new HttpsError(
        "invalid-argument",
        "scheduledAtMs must be 1 min to 30 days ahead"
      );
    }

    const db = admin.firestore();
    const notificationId = db.collection("notification_logs").doc().id;

    const job: Record<string, unknown> = {
      status: "pending",
      scheduledAt: admin.firestore.Timestamp.fromMillis(scheduledAtMs),
      title: t,
      body: b,
      notificationId,
      source: parseSource(data.source),
      audienceSegment:
        typeof data.audienceSegment === "string"
          ? data.audienceSegment.trim().toLowerCase()
          : "all",
      predictionMeta:
        data.predictionMeta && typeof data.predictionMeta === "object"
          ? data.predictionMeta
          : null,
      trendingAreaAr:
        typeof data.trendingAreaAr === "string"
          ? data.trendingAreaAr.trim().slice(0, 200)
          : null,
      createdBy: adminUid,
      createdAt: FieldValue.serverTimestamp(),
    };

    const ref = await db.collection(JOBS).add(job);
    return { ok: true, jobId: ref.id, notificationId };
  }
);

export const dispatchScheduledNotifications = onSchedule(
  {
    region: "us-central1",
    schedule: "every 5 minutes",
    timeZone: "Asia/Kuwait",
  },
  async () => {
    const db = admin.firestore();
    const now = admin.firestore.Timestamp.now();
    const snap = await db
      .collection(JOBS)
      .where("status", "==", "pending")
      .where("scheduledAt", "<=", now)
      .limit(8)
      .get();

    for (const doc of snap.docs) {
      const ref = doc.ref;
      try {
        const claimed = await db.runTransaction(
          async (tx): Promise<Record<string, unknown> | null> => {
            const s = await tx.get(ref);
            if (!s.exists) return null;
            const job = s.data()!;
            if (job.status !== "pending") return null;
            const sched = job.scheduledAt as admin.firestore.Timestamp | undefined;
            if (!sched || sched.toMillis() > Date.now()) {
              return null;
            }
            tx.update(ref, {
              status: "processing",
              processingAt: FieldValue.serverTimestamp(),
            });
            return job as Record<string, unknown>;
          }
        );

        if (claimed === null) continue;

        try {
          await deliverClaimedJob(ref, claimed);
        } catch (sendErr) {
          console.error("deliverClaimedJob", doc.id, sendErr);
          await ref
            .update({
              status: "failed",
              failedAt: FieldValue.serverTimestamp(),
              error: String(sendErr),
            })
            .catch(() => undefined);
        }
      } catch (e) {
        console.error("dispatchScheduledNotifications job", doc.id, e);
        await ref
          .update({
            status: "failed",
            failedAt: FieldValue.serverTimestamp(),
            error: String(e),
          })
          .catch(() => undefined);
      }
    }
  }
);
