/**
 * Self-learning weights for Instagram caption factor scoring (scheduled).
 * Reads caption_usage_logs + caption_clicks; updates caption_learning/*.
 */
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue } from "firebase-admin/firestore";

const USAGE_SAMPLE = 100;
const USAGE_FOR_COUNTS = 300;
const CLICK_SAMPLE = 500;
const WEIGHT_MIN = 0;
const WEIGHT_MAX = 0.5;
const ADJUST = 0.02;
const CTR_EPS = 0.001;
const MIN_PER_BUCKET = 3;

const VARIANTS = new Set(["A", "B", "C"]);

const FACTOR_DOCS: { docId: string; factor: string; logKey: string }[] = [
  { docId: "emoji", factor: "emoji", logKey: "hasEmoji" },
  { docId: "area", factor: "area", logKey: "hasArea" },
  { docId: "urgency", factor: "urgency", logKey: "hasUrgency" },
  { docId: "short_text", factor: "short_text", logKey: "shortText" },
];

const DEFAULT_WEIGHTS: Record<string, number> = {
  emoji: 0.1,
  area: 0.2,
  urgency: 0.2,
  short_text: 0.1,
};

function mean(arr: number[]): number {
  if (arr.length === 0) return 0;
  return arr.reduce((a, b) => a + b, 0) / arr.length;
}

function clampWeight(w: number): number {
  return Math.max(WEIGHT_MIN, Math.min(WEIGHT_MAX, w));
}

export const updateCaptionLearning = onSchedule(
  {
    schedule: "every 6 hours",
    region: "us-central1",
    timeoutSeconds: 120,
  },
  async () => {
    const db = admin.firestore();

    for (const { docId, factor } of FACTOR_DOCS) {
      const ref = db.collection("caption_learning").doc(docId);
      const cur = await ref.get();
      if (!cur.exists) {
        await ref.set({
          factor,
          weight: DEFAULT_WEIGHTS[docId] ?? 0.1,
          samples: 0,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    }

    const [usageSnap, usageCountSnap, clickSnap] = await Promise.all([
      db
        .collection("caption_usage_logs")
        .orderBy("createdAt", "desc")
        .limit(USAGE_SAMPLE)
        .get(),
      db
        .collection("caption_usage_logs")
        .orderBy("createdAt", "desc")
        .limit(USAGE_FOR_COUNTS)
        .get(),
      db
        .collection("caption_clicks")
        .orderBy("clickedAt", "desc")
        .limit(CLICK_SAMPLE)
        .get(),
    ]);

    const usageByVariant: Record<string, number> = {};
    for (const d of usageCountSnap.docs) {
      const id = String(d.data().captionId ?? "")
        .trim()
        .toUpperCase();
      if (!VARIANTS.has(id)) continue;
      usageByVariant[id] = (usageByVariant[id] ?? 0) + 1;
    }

    const clicksByVariant: Record<string, number> = {};
    for (const d of clickSnap.docs) {
      const id = String(d.data().captionId ?? "")
        .trim()
        .toUpperCase();
      if (!VARIANTS.has(id)) continue;
      clicksByVariant[id] = (clicksByVariant[id] ?? 0) + 1;
    }

    function variantCtr(cid: string): number {
      const u = usageByVariant[cid] ?? 0;
      const c = clicksByVariant[cid] ?? 0;
      if (u <= 0) return 0;
      return c / u;
    }

    for (const { docId, factor, logKey } of FACTOR_DOCS) {
      const trueCtrs: number[] = [];
      const falseCtrs: number[] = [];

      for (const d of usageSnap.docs) {
        const data = d.data();
        const cid = String(data.captionId ?? "")
          .trim()
          .toUpperCase();
        if (!VARIANTS.has(cid)) continue;

        const factors = data.factors as Record<string, unknown> | undefined;
        const flag = factors && factors[logKey] === true;
        const ctr = variantCtr(cid);
        if (flag) trueCtrs.push(ctr);
        else falseCtrs.push(ctr);
      }

      const tAvg = mean(trueCtrs);
      const fAvg = mean(falseCtrs);

      const ref = db.collection("caption_learning").doc(docId);
      const cur = await ref.get();
      let weight =
        typeof cur.data()?.weight === "number"
          ? cur.data()!.weight
          : DEFAULT_WEIGHTS[docId] ?? 0.1;
      weight = clampWeight(weight);

      let samples = (cur.data()?.samples as number) ?? 0;

      if (
        trueCtrs.length >= MIN_PER_BUCKET &&
        falseCtrs.length >= MIN_PER_BUCKET
      ) {
        if (tAvg > fAvg + CTR_EPS) {
          weight = clampWeight(weight + ADJUST);
        } else if (tAvg < fAvg - CTR_EPS) {
          weight = clampWeight(weight - ADJUST);
        }
        samples += trueCtrs.length + falseCtrs.length;
      }

      await ref.set(
        {
          factor,
          weight,
          samples,
          updatedAt: FieldValue.serverTimestamp(),
          lastTrueAvg: tAvg,
          lastFalseAvg: fAvg,
        },
        { merge: true }
      );
    }

    console.log("updateCaptionLearning: done");
  }
);
