/**
 * تعلّم أوزان عوامل نص الإشعار من أداء السجلات الأخيرة (لا إرسال — تعديل أوزان فقط).
 */
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue } from "firebase-admin/firestore";

export const FACTOR_IDS = [
  "hasEmoji",
  "hasArea",
  "hasUrgency",
  "shortText",
] as const;

export type FactorId = (typeof FACTOR_IDS)[number];

export const DEFAULT_LEARNING_WEIGHTS: Record<FactorId, number> = {
  hasEmoji: 0.1,
  hasArea: 0.2,
  hasUrgency: 0.15,
  shortText: 0.05,
};

const WEIGHT_MIN = 0;
const WEIGHT_MAX = 0.5;
const ADJUST_STEP = 0.02;
const CTR_EPS = 0.0008;
const MIN_PER_BUCKET = 3;
const LOG_LIMIT = 100;
const CTR_BLEND = 0.3;
const CONVERSION_BLEND = 0.7;

function num(v: unknown): number {
  if (typeof v === "number" && !Number.isNaN(v)) return v;
  if (typeof v === "string") {
    const x = parseFloat(v);
    return Number.isNaN(x) ? 0 : x;
  }
  return 0;
}

function mean(arr: number[]): number {
  if (arr.length === 0) return 0;
  return arr.reduce((a, b) => a + b, 0) / arr.length;
}

function readActualCtr(data: Record<string, unknown>): number {
  const a = num(data.actualCTR);
  if (a > 0) return a;
  const sent = num(data.sentCount);
  const clicks = num(data.clickCount);
  if (sent <= 0) return 0;
  return clicks / sent;
}

/** معدل التحويل من الحقل المخزّن أو conversionCount / sentCount */
function readConversionRate(data: Record<string, unknown>): number {
  const sent = num(data.sentCount);
  const stored = num(data.conversionRate);
  if (stored > 0) return Math.min(1, stored);
  const cc = num(data.conversionCount);
  if (sent <= 0) return 0;
  return Math.min(1, cc / sent);
}

/** إشارة التعلّم: دمج النقر والتحويل الفعلي */
function readLearningSignal(data: Record<string, unknown>): number {
  const ctr = readActualCtr(data);
  const cr = readConversionRate(data);
  return CTR_BLEND * ctr + CONVERSION_BLEND * cr;
}

function readFactor(
  factors: Record<string, unknown> | undefined,
  key: FactorId
): boolean {
  if (!factors || typeof factors !== "object") return false;
  return factors[key] === true;
}

/**
 * يضمن وجود وثائق `notification_learning/{factorId}` بالأوزان الابتدائية.
 */
export async function ensureLearningDocs(
  db: admin.firestore.Firestore
): Promise<void> {
  const batch = db.batch();
  for (const factor of FACTOR_IDS) {
    const ref = db.collection("notification_learning").doc(factor);
    batch.set(
      ref,
      {
        factor,
        weight: DEFAULT_LEARNING_WEIGHTS[factor],
        samples: 0,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }
  await batch.commit();
}

/**
 * يحدّث أوزان العوامل من آخر [LOG_LIMIT] سجلًا لها factors ومرسلون > 0.
 */
export async function updateLearningWeights(): Promise<void> {
  const db = admin.firestore();
  await ensureLearningDocs(db);

  const snap = await db
    .collection("notification_logs")
    .orderBy("createdAt", "desc")
    .limit(LOG_LIMIT)
    .get();

  const rows = snap.docs
    .map((d) => ({ id: d.id, data: d.data() }))
    .filter(({ data }) => {
      const sent = num(data.sentCount);
      return sent > 0 && data.factors && typeof data.factors === "object";
    });

  if (rows.length < 8) {
    return;
  }

  for (const factor of FACTOR_IDS) {
    const ref = db.collection("notification_learning").doc(factor);
    const curSnap = await ref.get();
    const cur = curSnap.data();
    let w =
      typeof cur?.weight === "number"
        ? cur.weight
        : DEFAULT_LEARNING_WEIGHTS[factor];
    w = Math.max(WEIGHT_MIN, Math.min(WEIGHT_MAX, w));

    const signalWhenTrue: number[] = [];
    const signalWhenFalse: number[] = [];

    for (const { data } of rows) {
      const factors = data.factors as Record<string, unknown> | undefined;
      const signal = readLearningSignal(data);
      const flag = readFactor(factors, factor);
      if (flag) signalWhenTrue.push(signal);
      else signalWhenFalse.push(signal);
    }

    if (
      signalWhenTrue.length < MIN_PER_BUCKET ||
      signalWhenFalse.length < MIN_PER_BUCKET
    ) {
      await ref.set(
        {
          factor,
          samples: rows.length,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      continue;
    }

    const avgT = mean(signalWhenTrue);
    const avgF = mean(signalWhenFalse);

    if (avgT > avgF + CTR_EPS) {
      w += ADJUST_STEP;
    } else if (avgT < avgF - CTR_EPS) {
      w -= ADJUST_STEP;
    }

    w = Math.max(WEIGHT_MIN, Math.min(WEIGHT_MAX, w));

    await ref.set(
      {
        factor,
        weight: w,
        samples: rows.length,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }
}

/** كل 6 ساعات — يحدّث الأوزان فقط (لا إشعارات). */
export const notificationLearningSchedule = onSchedule(
  {
    schedule: "0 */6 * * *",
    region: "us-central1",
    timeZone: "Asia/Kuwait",
  },
  async () => {
    try {
      await updateLearningWeights();
    } catch (e) {
      console.error("notificationLearningSchedule", e);
    }
  }
);
