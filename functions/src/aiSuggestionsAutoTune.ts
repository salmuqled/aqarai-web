import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";

type AiDayAgg = {
  totalShown?: number;
  totalClicked?: number;
  totalConversions?: number;
  totalRevenue?: number;
};

function yyyymmddUTC(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function clamp01(x: number): number {
  if (!Number.isFinite(x)) return 0;
  if (x < 0) return 0;
  if (x > 1) return 1;
  return x;
}

function clamp(x: number, min: number, max: number): number {
  if (!Number.isFinite(x)) return min;
  if (x < min) return min;
  if (x > max) return max;
  return x;
}

export const autoTuneAiSuggestionsConfig = onSchedule(
  {
    region: "us-central1",
    schedule: "every day 02:10",
    timeZone: "UTC",
  },
  async () => {
    const db = admin.firestore();

    const configRef = db.collection("analytics").doc("ai_suggestions_config");
    const existing = await configRef.get();
    const existingData = (existing.data() ?? {}) as Record<string, unknown>;
    const manualOverride = existingData["manualOverride"] === true;
    if (manualOverride) {
      // Safety: when manually overridden, do not auto-update.
      return;
    }

    // Evaluate last 7 days (including today) from daily aggregates.
    const now = new Date();
    const start = new Date(now.getTime() - 6 * 24 * 60 * 60 * 1000);
    const startDay = yyyymmddUTC(start);
    const endDay = yyyymmddUTC(now);

    const snap = await db
      .collection("analytics")
      .where("kind", "==", "ai_suggestions_day")
      .where("day", ">=", startDay)
      .where("day", "<=", endDay)
      .get();

    let shown = 0;
    let clicked = 0;
    let conversions = 0;
    let revenue = 0;

    for (const d of snap.docs) {
      const m = d.data() as AiDayAgg;
      shown += typeof m.totalShown === "number" ? m.totalShown : 0;
      clicked += typeof m.totalClicked === "number" ? m.totalClicked : 0;
      conversions += typeof m.totalConversions === "number" ? m.totalConversions : 0;
      revenue += typeof m.totalRevenue === "number" ? m.totalRevenue : 0;
    }

    const ctr = shown > 0 ? clicked / shown : 0;
    const convRate = clicked > 0 ? conversions / clicked : 0;
    const revenuePerSuggestion = shown > 0 ? revenue / shown : 0;

    // Optional: use global popularity from payment_logs to set default plan.
    // Keep reads bounded.
    const paySnap = await db
      .collection("payment_logs")
      .where("action", "==", "featured_ad_payment")
      .orderBy("timestamp", "desc")
      .limit(2500)
      .get();

    const planCounts: Record<string, number> = {};
    for (const p of paySnap.docs) {
      const m = p.data() as Record<string, unknown>;
      const durRaw = m["durationDays"];
      const dur =
        typeof durRaw === "number"
          ? Math.floor(durRaw)
          : Number.parseInt(String(durRaw ?? ""), 10);
      if (!Number.isFinite(dur) || dur <= 0) continue;
      const k = String(dur);
      planCounts[k] = (planCounts[k] ?? 0) + 1;
    }

    let topPlan: number | null = null;
    let topCount = 0;
    let totalPlans = 0;
    for (const [k, c] of Object.entries(planCounts)) {
      totalPlans += c;
      if (c > topCount) {
        topCount = c;
        topPlan = Number.parseInt(k, 10);
      }
    }
    const dominance = totalPlans > 0 ? topCount / totalPlans : 0;

    // --- Rules -> config ---
    const suggestionVariant = ctr < 0.10 ? "B" : "A";

    // Urgency level drives stronger visuals + potentially more aggressive copy.
    // 1 = normal, 2 = stronger emphasis.
    const urgencyLevel = convRate < 0.10 ? 2 : 1;

    // Default plan: if one dominates, use it; else keep 30d (best value).
    const defaultPlanDays =
      topPlan && dominance >= 0.65 ? topPlan : 30;

    // Exposure: scale thresholds. Strong performance => show more suggestions.
    // 1.0 = baseline. Up to 1.6 for strong performance.
    const performanceStrong = ctr >= 0.15 && convRate >= 0.20;
    const exposureMultiplier = performanceStrong ? 1.4 : 1.0;

    // If revenue per suggestion is very low, reduce exposure (be selective).
    const selective = revenuePerSuggestion > 0 && revenuePerSuggestion < 0.25;
    const effectiveExposureMultiplier = selective ? 0.85 : exposureMultiplier;
    const clampedExposure = clamp(effectiveExposureMultiplier, 0.5, 2.0);

    // Store a small "basis snapshot" so you can track before/after of the change.
    const basis = {
      windowDays: 7,
      startDay,
      endDay,
      totals: { shown, clicked, conversions, revenue },
      rates: {
        ctr: clamp01(ctr),
        conversionRate: clamp01(convRate),
        revenuePerSuggestion,
      },
      planDominance: dominance,
      topPlanDays: topPlan,
    };

    const changeSummary = [
      `auto_tune: variant=${suggestionVariant}`,
      `defaultPlan=${defaultPlanDays}d`,
      `urgency=${urgencyLevel}`,
      `exposure=${clampedExposure.toFixed(2)}`,
      `ctr=${(ctr * 100).toFixed(1)}%`,
      `conv=${(convRate * 100).toFixed(1)}%`,
    ].join("; ");

    await db.runTransaction(async (tx) => {
      const curSnap = await tx.get(configRef);
      const cur = (curSnap.data() ?? {}) as Record<string, unknown>;
      const prevV =
        typeof cur["configVersion"] === "number"
          ? Math.floor(cur["configVersion"] as number)
          : 0;
      const nextV = prevV + 1;

      const mergePayload: Record<string, unknown> = {
        kind: "ai_suggestions_config",
        updatedAt: FieldValue.serverTimestamp(),
        updatedBy: "system:auto_tune",
        changeSummary,
        configVersion: nextV,
        suggestionVariant,
        defaultPlanDays,
        urgencyLevel,
        exposureMultiplier: clampedExposure,
        basis,
        aiEnabled: cur["aiEnabled"] !== false,
        manualOverride: cur["manualOverride"] === true,
      };

      tx.set(configRef, mergePayload, { merge: true });

      const plainSnapshot: Record<string, unknown> = {
        kind: mergePayload.kind,
        aiEnabled: mergePayload.aiEnabled,
        manualOverride: mergePayload.manualOverride,
        suggestionVariant: mergePayload.suggestionVariant,
        defaultPlanDays: mergePayload.defaultPlanDays,
        urgencyLevel: mergePayload.urgencyLevel,
        exposureMultiplier: mergePayload.exposureMultiplier,
        configVersion: mergePayload.configVersion,
        basis: mergePayload.basis,
        changeSummary,
        updatedBy: "system:auto_tune",
      };

      const histRef = db.collection("ai_config_history").doc();
      tx.set(histRef, {
        configVersion: nextV,
        updatedBy: "system:auto_tune",
        changeSummary,
        snapshot: plainSnapshot,
        createdAt: FieldValue.serverTimestamp(),
      });
    });
  },
);

