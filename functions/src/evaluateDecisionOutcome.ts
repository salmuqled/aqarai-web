/**
 * Hourly: link auto_decision_logs to notification performance; adjust per-dimension trust.
 * - ≥6h after send: apply CTR vs expectedCtr (delta * 0.1) to caption/time/audience trust.
 * - ≥24h: conversion boost, auto-shield counters, auto-executed trust nudge (+0.02 / -0.04), mark evaluated.
 */
import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue } from "firebase-admin/firestore";

const LOGS = "auto_decision_logs";
const STATE = "auto_decision_learning";
const STATE_DOC = "state";
const NOTIFICATION_LOGS = "notification_logs";

function num(v: unknown): number {
  if (typeof v === "number" && !Number.isNaN(v)) return v;
  if (typeof v === "string") {
    const x = parseFloat(v);
    return Number.isNaN(x) ? 0 : x;
  }
  return 0;
}

function clampTrust(x: number): number {
  return Math.min(1, Math.max(0.5, x));
}

function readTrustDim(
  prev: Record<string, unknown>,
  key: string,
  patternFallback: number
): number {
  const v = num(prev[key]);
  if (v >= 0.5 && v <= 1) return v;
  return patternFallback;
}

async function adjustStateTrusts(args: {
  ctrDeltaScale: number;
  conversionBoostCaptionAudience: boolean;
}): Promise<void> {
  const db = admin.firestore();
  const stateRef = db.collection(STATE).doc(STATE_DOC);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(stateRef);
    const prev = snap.data() ?? {};
    const pRaw = num(prev.patternTrust);
    const pattern =
      pRaw >= 0.5 && pRaw <= 1 ? pRaw : 1;
    let c = readTrustDim(prev, "captionTrust", pattern);
    let t = readTrustDim(prev, "timeTrust", pattern);
    let a = readTrustDim(prev, "audienceTrust", pattern);

    const d = args.ctrDeltaScale;
    c = clampTrust(c + d);
    t = clampTrust(t + d);
    a = clampTrust(a + d);

    if (args.conversionBoostCaptionAudience) {
      c = clampTrust(c + 0.02);
      a = clampTrust(a + 0.02);
    }

    const patternTrust = clampTrust((c + t + a) / 3);
    tx.set(
      stateRef,
      {
        captionTrust: c,
        timeTrust: t,
        audienceTrust: a,
        patternTrust,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  });
}

/**
 * After 24h outcome: shield / auto counters / manual recovery + extra trust if autoExecuted.
 */
async function applyPost24hLearning(args: {
  autoExecuted: boolean;
  success: boolean;
}): Promise<void> {
  const db = admin.firestore();
  const stateRef = db.collection(STATE).doc(STATE_DOC);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(stateRef);
    const prev = snap.data() ?? {};
    const pRaw = num(prev.patternTrust);
    const pattern =
      pRaw >= 0.5 && pRaw <= 1 ? pRaw : 1;
    let c = readTrustDim(prev, "captionTrust", pattern);
    let t = readTrustDim(prev, "timeTrust", pattern);
    let a = readTrustDim(prev, "audienceTrust", pattern);

    let failures = Math.round(num(prev.autoFailures));
    let successes = Math.round(num(prev.autoSuccesses));
    let shield = prev.autoShieldEnabled === true;
    let manualStreak = Math.round(num(prev.manualRecoveryStreak));

    if (args.autoExecuted) {
      if (args.success) {
        successes += 1;
        failures = 0;
        const bump = 0.02;
        c = clampTrust(c + bump);
        t = clampTrust(t + bump);
        a = clampTrust(a + bump);
      } else {
        failures += 1;
        const bump = -0.04;
        c = clampTrust(c + bump);
        t = clampTrust(t + bump);
        a = clampTrust(a + bump);
        if (failures >= 3) {
          shield = true;
          manualStreak = 0;
        }
      }
    } else if (shield) {
      if (args.success) {
        manualStreak += 1;
        if (manualStreak >= 5) {
          shield = false;
          failures = 0;
          manualStreak = 0;
        }
      } else {
        manualStreak = 0;
      }
    }

    const patternTrust = clampTrust((c + t + a) / 3);
    tx.set(
      stateRef,
      {
        captionTrust: c,
        timeTrust: t,
        audienceTrust: a,
        patternTrust,
        autoFailures: failures,
        autoSuccesses: successes,
        autoShieldEnabled: shield,
        manualRecoveryStreak: manualStreak,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  });
}

export const evaluateDecisionOutcome = onSchedule(
  {
    region: "us-central1",
    schedule: "every 60 minutes",
    timeZone: "Asia/Kuwait",
  },
  async () => {
    const db = admin.firestore();
    const now = Date.now();

    let snap;
    try {
      snap = await db.collection(LOGS).where("evaluated", "==", false).limit(40).get();
    } catch (e) {
      console.error("evaluateDecisionOutcome query", e);
      return;
    }

    for (const doc of snap.docs) {
      const d = doc.data();
      const notificationId =
        typeof d.notificationId === "string" ? d.notificationId.trim() : "";
      if (!notificationId) continue;

      const expectedCtr = num(d.expectedCtr);
      const outcomeCtrApplied = d.outcomeCtrApplied === true;
      const autoExecuted = d.autoExecuted === true;

      let nSnap;
      try {
        nSnap = await db.collection(NOTIFICATION_LOGS).doc(notificationId).get();
      } catch (e) {
        console.error("evaluateDecisionOutcome read notification", notificationId, e);
        continue;
      }

      if (!nSnap.exists) {
        try {
          await doc.ref.update({
            evaluated: true,
            finalCtr: 0,
            conversions: 0,
            evaluatedAt: FieldValue.serverTimestamp(),
            outcomeSkipReason: "notification_log_missing",
          });
        } catch (e) {
          console.error("evaluateDecisionOutcome skip missing", doc.id, e);
        }
        continue;
      }

      const nd = nSnap.data()!;
      const created = nd.createdAt as admin.firestore.Timestamp | undefined;
      if (!created) continue;

      const ageH = (now - created.toMillis()) / 3600000;
      const sent = num(nd.sentCount);
      const clicks = num(nd.clickCount);
      const actualCtr = sent > 0 ? clicks / sent : 0;
      const conversions = Math.round(num(nd.conversionCount));

      const delta = actualCtr - expectedCtr;
      const ctrDeltaScale = delta * 0.1;
      const success = actualCtr >= expectedCtr;

      try {
        if (ageH >= 24) {
          const needCtr = !outcomeCtrApplied;
          const needConv = conversions > 0;
          if (needCtr && needConv) {
            await adjustStateTrusts({
              ctrDeltaScale,
              conversionBoostCaptionAudience: true,
            });
          } else if (needCtr) {
            await adjustStateTrusts({
              ctrDeltaScale,
              conversionBoostCaptionAudience: false,
            });
          } else if (needConv) {
            await adjustStateTrusts({
              ctrDeltaScale: 0,
              conversionBoostCaptionAudience: true,
            });
          }

          await doc.ref.update({
            evaluated: true,
            finalCtr: actualCtr,
            conversions,
            evaluatedAt: FieldValue.serverTimestamp(),
            outcomeCtrApplied: true,
          });

          await applyPost24hLearning({ autoExecuted, success });

          const deltaPct = delta * 100;
          await db.collection(STATE).doc(STATE_DOC).set(
            {
              outcomeLearningDeltaPct: deltaPct,
              outcomeLearningBeatExpectation: delta > 0,
              outcomeLearningEvaluatedAt: FieldValue.serverTimestamp(),
              updatedAt: FieldValue.serverTimestamp(),
            },
            { merge: true }
          );
        } else if (ageH >= 6 && !outcomeCtrApplied) {
          await adjustStateTrusts({
            ctrDeltaScale,
            conversionBoostCaptionAudience: false,
          });
          await doc.ref.update({
            outcomeCtrApplied: true,
          });
        }
      } catch (e) {
        console.error("evaluateDecisionOutcome process", doc.id, e);
      }
    }
  }
);
