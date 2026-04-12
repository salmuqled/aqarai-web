import * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onDocumentWritten } from "firebase-functions/v2/firestore";

const db = admin.firestore();

type SuggestionEvent = {
  event?: string;
  suggestionType?: string;
  amountKwd?: number;
  createdAt?: Timestamp | null;
};

function asString(x: unknown): string {
  return typeof x === "string" ? x.trim() : "";
}

function asNumber(x: unknown): number {
  if (typeof x === "number" && Number.isFinite(x)) return x;
  if (typeof x === "string") {
    const n = Number(x.trim());
    if (Number.isFinite(n)) return n;
  }
  return 0;
}

function dayKeyUTC(ts: Timestamp | null): string {
  const d = ts ? ts.toDate() : new Date();
  // YYYY-MM-DD (UTC)
  return d.toISOString().slice(0, 10);
}

function analyticsDocId(day: string): string {
  return `ai_suggestions_${day}`;
}

function deltaForEvent(e: SuggestionEvent): {
  incShown: number;
  incClicked: number;
  incConversions: number;
  incRevenue: number;
  type: string;
} {
  const ev = asString(e.event);
  const type = asString(e.suggestionType) || "unknown";
  const amount = asNumber(e.amountKwd);

  if (ev === "suggestion_shown") {
    return { incShown: 1, incClicked: 0, incConversions: 0, incRevenue: 0, type };
  }
  if (ev === "suggestion_clicked") {
    return { incShown: 0, incClicked: 1, incConversions: 0, incRevenue: 0, type };
  }
  if (ev === "ai_conversion_success") {
    return {
      incShown: 0,
      incClicked: 0,
      incConversions: 1,
      incRevenue: amount,
      type,
    };
  }
  return { incShown: 0, incClicked: 0, incConversions: 0, incRevenue: 0, type };
}

/**
 * Daily aggregation for AI suggestions analytics.
 *
 * Source: `feature_suggestion_events/{eventId}`
 * Target: `analytics/ai_suggestions_YYYY-MM-DD`
 *
 * IMPORTANT: To avoid double counting, we only aggregate on CREATE and DELETE:
 * - create: before !exists && after exists => +1
 * - delete: before exists && after !exists => -1
 *
 * For updates/merges (e.g. `suggestion_shown` using SetOptions(merge:true)),
 * we ignore changes to keep counters stable and idempotent.
 */
export const onFeatureSuggestionEventWritten = onDocumentWritten(
  { region: "us-central1", document: "feature_suggestion_events/{eventId}" },
  async (change) => {
    const beforeExists = change.data?.before.exists ?? false;
    const afterExists = change.data?.after.exists ?? false;

    const before = beforeExists
      ? (change.data!.before.data() as Record<string, unknown>)
      : null;
    const after = afterExists
      ? (change.data!.after.data() as Record<string, unknown>)
      : null;

    // Create only
    if (!beforeExists && afterExists && after) {
      const e: SuggestionEvent = {
        event: asString(after["event"]),
        suggestionType: asString(after["suggestionType"]),
        amountKwd: asNumber(after["amountKwd"]),
        createdAt: after["createdAt"] instanceof Timestamp ? after["createdAt"] : null,
      };

      const day = dayKeyUTC(e.createdAt ?? null);
      const docRef = db.collection("analytics").doc(analyticsDocId(day));
      const d = deltaForEvent(e);

      const updates: Record<string, unknown> = {
        kind: "ai_suggestions_day",
        day,
        updatedAt: FieldValue.serverTimestamp(),
        totalShown: FieldValue.increment(d.incShown),
        totalClicked: FieldValue.increment(d.incClicked),
        totalConversions: FieldValue.increment(d.incConversions),
        totalRevenue: FieldValue.increment(d.incRevenue),
        [`bySuggestionType.${d.type}.shown`]: FieldValue.increment(d.incShown),
        [`bySuggestionType.${d.type}.clicked`]: FieldValue.increment(d.incClicked),
        [`bySuggestionType.${d.type}.conversions`]: FieldValue.increment(d.incConversions),
        [`bySuggestionType.${d.type}.revenue`]: FieldValue.increment(d.incRevenue),
      };

      await docRef.set(updates, { merge: true });
      return;
    }

    // Delete only (rare, but keeps aggregates correct if events are removed)
    if (beforeExists && !afterExists && before) {
      const e: SuggestionEvent = {
        event: asString(before["event"]),
        suggestionType: asString(before["suggestionType"]),
        amountKwd: asNumber(before["amountKwd"]),
        createdAt: before["createdAt"] instanceof Timestamp ? before["createdAt"] : null,
      };

      const day = dayKeyUTC(e.createdAt ?? null);
      const docRef = db.collection("analytics").doc(analyticsDocId(day));
      const d = deltaForEvent(e);

      const updates: Record<string, unknown> = {
        kind: "ai_suggestions_day",
        day,
        updatedAt: FieldValue.serverTimestamp(),
        totalShown: FieldValue.increment(-d.incShown),
        totalClicked: FieldValue.increment(-d.incClicked),
        totalConversions: FieldValue.increment(-d.incConversions),
        totalRevenue: FieldValue.increment(-d.incRevenue),
        [`bySuggestionType.${d.type}.shown`]: FieldValue.increment(-d.incShown),
        [`bySuggestionType.${d.type}.clicked`]: FieldValue.increment(-d.incClicked),
        [`bySuggestionType.${d.type}.conversions`]: FieldValue.increment(-d.incConversions),
        [`bySuggestionType.${d.type}.revenue`]: FieldValue.increment(-d.incRevenue),
      };

      await docRef.set(updates, { merge: true });
      return;
    }

    // Updates ignored (idempotency over perfect update tracking).
  },
);

