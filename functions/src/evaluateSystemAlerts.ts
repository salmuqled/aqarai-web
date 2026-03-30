/**
 * Hourly: sync fixed-id alerts in `system_alerts` (no duplicate docs per condition).
 * - Shield active → `alert_shield` (critical); removed when shield clears.
 * - Outcome CTR below expectation beyond threshold → `alert_ctr_drop` (warning).
 * - Recent campaigns: high sends, zero conversions → `alert_zero_conversions` (warning).
 */
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

const ALERTS = "system_alerts";
const LEARNING = "auto_decision_learning";
const STATE_DOC = "state";
const NOTIF_LOGS = "notification_logs";

const DOC_SHIELD = "alert_shield";
const DOC_CTR = "alert_ctr_drop";
const DOC_ZERO = "alert_zero_conversions";

/** Delta stored as (actual − expected) × 100 (percentage points). */
const CTR_DROP_THRESHOLD_PP = -3;
const OUTCOME_MAX_AGE_H = 72;
const ZERO_CONV_MIN_SENT = 80;
const ZERO_CONV_SAMPLE = 25;

function num(v: unknown): number {
  if (typeof v === "number" && !Number.isNaN(v)) return v;
  if (typeof v === "string") {
    const x = parseFloat(v);
    return Number.isNaN(x) ? 0 : x;
  }
  return 0;
}

function ni(v: unknown): number {
  if (typeof v === "number" && Number.isFinite(v)) return Math.round(v);
  if (typeof v === "string") {
    const x = parseInt(v, 10);
    return Number.isNaN(x) ? 0 : x;
  }
  return 0;
}

async function upsertAlert(
  db: admin.firestore.Firestore,
  docId: string,
  payload: Record<string, unknown>
): Promise<void> {
  const ref = db.collection(ALERTS).doc(docId);
  const snap = await ref.get();
  const base = {
    ...payload,
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (!snap.exists) {
    await ref.set({
      ...base,
      read: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  } else {
    await ref.set(base, { merge: true });
  }
}

async function removeAlert(
  db: admin.firestore.Firestore,
  docId: string
): Promise<void> {
  try {
    await db.collection(ALERTS).doc(docId).delete();
  } catch (e) {
    console.warn("evaluateSystemAlerts delete", docId, e);
  }
}

export const evaluateSystemAlerts = onSchedule(
  {
    region: "us-central1",
    schedule: "every 60 minutes",
    timeZone: "Asia/Kuwait",
  },
  async () => {
    const db = admin.firestore();
    let state: Record<string, unknown> = {};
    try {
      const s = await db.collection(LEARNING).doc(STATE_DOC).get();
      state = s.data() ?? {};
    } catch (e) {
      console.error("evaluateSystemAlerts state", e);
    }

    const shield = state.autoShieldEnabled === true;
    if (shield) {
      await upsertAlert(db, DOC_SHIELD, {
        type: "shield",
        severity: "critical",
        titleEn: "Auto shield active",
        titleAr: "درع الإيقاف التلقائي مفعّل",
        messageEn:
          "Automatic marketing execution is blocked until performance recovers or you disable the shield.",
        messageAr:
          "التنفيذ التلقائي للتسويق موقوف حتى يتحسن الأداء أو تقوم بإيقاف الدرع يدوياً.",
      });
    } else {
      await removeAlert(db, DOC_SHIELD);
    }

    const deltaPct = num(state.outcomeLearningDeltaPct);
    const beat = state.outcomeLearningBeatExpectation === true;
    const evalAt = state.outcomeLearningEvaluatedAt as Timestamp | undefined;
    const evalMs = evalAt?.toMillis() ?? 0;
    const ageH = evalMs > 0 ? (Date.now() - evalMs) / 3600000 : 999;

    const ctrDrop =
      ageH <= OUTCOME_MAX_AGE_H &&
      !beat &&
      deltaPct <= CTR_DROP_THRESHOLD_PP;

    if (ctrDrop) {
      await upsertAlert(db, DOC_CTR, {
        type: "ctr_drop",
        severity: "warning",
        titleEn: "CTR below expectation",
        titleAr: "معدل النقر أقل من المتوقع",
        messageEn: `Last evaluated outcome is ${deltaPct.toFixed(1)} pp vs expected CTR. Review captions, timing, and audience.`,
        messageAr: `آخر تقييم للنتيجة أقل بمقدار ${deltaPct.toFixed(1)} نقطة مئوية عن المتوقع. راجع الكابشن والتوقيت والجمهور.`,
        metaDeltaPct: deltaPct,
      });
    } else {
      await removeAlert(db, DOC_CTR);
    }

    let totalSent = 0;
    let totalConv = 0;
    try {
      const logs = await db
        .collection(NOTIF_LOGS)
        .orderBy("createdAt", "desc")
        .limit(ZERO_CONV_SAMPLE)
        .get();
      for (const d of logs.docs) {
        const m = d.data();
        totalSent += ni(m.sentCount);
        totalConv += ni(m.conversionCount);
      }
    } catch (e) {
      console.error("evaluateSystemAlerts notification_logs", e);
    }

    const zeroConv = totalSent >= ZERO_CONV_MIN_SENT && totalConv === 0;
    if (zeroConv) {
      await upsertAlert(db, DOC_ZERO, {
        type: "zero_conversions",
        severity: "warning",
        titleEn: "No conversions on recent pushes",
        titleAr: "لا تحويلات في الإشعارات الأخيرة",
        messageEn: `Last ${ZERO_CONV_SAMPLE} campaigns: ${totalSent} sends, 0 conversions. Check funnels and listing quality.`,
        messageAr: `آخر ${ZERO_CONV_SAMPLE} حملة: ${totalSent} إرسال و0 تحويل. راجع مسار المستخدم وجودة العروض.`,
        metaSentSample: totalSent,
      });
    } else {
      await removeAlert(db, DOC_ZERO);
    }
  }
);
