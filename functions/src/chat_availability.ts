/**
 * Chat Availability Layer.
 *
 * Exposes two surfaces:
 *
 *   1. `filterAvailablePropertyIdsForChat` — library function. Given a batch
 *      of candidate property IDs and an ISO date window, returns the SUBSET
 *      that is AVAILABLE for that window (i.e. not reserved, not blocked).
 *      This is the primitive the AI chat pipeline can call internally without
 *      a round-trip.
 *
 *   2. `filterChatAvailability` — authenticated httpsCallable. Thin wrapper
 *      around (1) for the Flutter client. Accepts `propertyIds[]`,
 *      `startDate`, `endDate`; returns `{ allowedPropertyIds[] }`.
 *
 * Both surfaces reuse `fetchUnavailablePropertyIdsBatched` from
 * `./shared_availability` — the SAME primitive already in production for the
 * daily-rent marketplace search (`searchDailyProperties`). We do not re-
 * implement overlap logic, chunk size, pending-payment holds, or
 * `blocked_dates` parsing anywhere: this file is the minimum surface to let
 * the AI chat ride on the existing booking safety rails.
 *
 * Contract:
 *   - `startDate` MUST be < `endDate` (half-open; hotel convention).
 *   - Empty `propertyIds` returns an empty allowed set (no queries issued).
 *   - A non-empty `propertyIds` with invalid dates throws
 *     `invalid-argument` from the callable (the library returns an empty set
 *     and logs, because callers of the library shouldn't have to handle
 *     throws).
 *   - Authentication on the callable: caller must be signed in. We don't rate
 *     limit here because the only expected caller is the already-rate-limited
 *     chat pipeline; each turn issues at most one invocation.
 *   - No PII: inputs are property IDs only; no guest data, no message text,
 *     no booking doc IDs.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import {
  fetchUnavailablePropertyIdsBatched,
  parseIsoToTimestamp,
} from "./shared_availability";

const db = admin.firestore();

/** Upper bound for `propertyIds` in a single chat availability call. */
const CHAT_AVAILABILITY_MAX_IDS = 200;

export interface FilterAvailablePropertyIdsInput {
  propertyIds: string[];
  /** ISO-8601 inclusive check-in. Same wire format as Date Intelligence Layer. */
  startDate: string;
  /** ISO-8601 exclusive check-out. */
  endDate: string;
}

/**
 * Library entry point. Returns the subset of [input.propertyIds] that is
 * AVAILABLE over `[startDate, endDate)`. Never throws for bad input — returns
 * an empty set instead, because chat-side callers want to degrade gracefully
 * to "no date gating" rather than crash the whole search.
 */
export async function filterAvailablePropertyIdsForChat(
  input: FilterAvailablePropertyIdsInput
): Promise<Set<string>> {
  const ids = Array.isArray(input.propertyIds)
    ? input.propertyIds
        .map((x) => (typeof x === "string" ? x.trim() : ""))
        .filter((x) => x.length > 0)
    : [];
  const unique = Array.from(new Set(ids));
  if (unique.length === 0) return new Set<string>();

  const start = parseIsoToTimestamp(input.startDate);
  const end = parseIsoToTimestamp(input.endDate);
  if (!start || !end) {
    console.warn({
      tag: "chat_availability.invalid_dates",
      startRaw: String(input.startDate ?? ""),
      endRaw: String(input.endDate ?? ""),
      idCount: unique.length,
    });
    return new Set<string>();
  }
  if (start.toMillis() >= end.toMillis()) {
    console.warn({
      tag: "chat_availability.non_positive_range",
      startMs: start.toMillis(),
      endMs: end.toMillis(),
      idCount: unique.length,
    });
    return new Set<string>();
  }

  const unavailable = await fetchUnavailablePropertyIdsBatched(
    db,
    unique,
    start,
    end,
    Date.now()
  );

  const allowed = new Set<string>();
  for (const id of unique) if (!unavailable.has(id)) allowed.add(id);
  return allowed;
}

/**
 * Authenticated callable for the Flutter client. Mirrors the contract of the
 * library function above. Returns the preserved ORDER of `propertyIds` (input
 * order), filtered down to only the available ones. Order-preservation lets
 * the client skip a second sort pass after filtering.
 */
export const filterChatAvailability = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required");
    }
    const data = (request.data as Record<string, unknown>) || {};
    const rawIds = Array.isArray(data.propertyIds)
      ? (data.propertyIds as unknown[])
      : [];
    const propertyIds = rawIds
      .map((x) => (typeof x === "string" ? x.trim() : ""))
      .filter((x) => x.length > 0);

    if (propertyIds.length === 0) {
      return { allowedPropertyIds: [] };
    }
    if (propertyIds.length > CHAT_AVAILABILITY_MAX_IDS) {
      throw new HttpsError(
        "invalid-argument",
        "Too many propertyIds (max " + CHAT_AVAILABILITY_MAX_IDS + ")"
      );
    }

    const startRaw = data.startDate;
    const endRaw = data.endDate;
    const start = parseIsoToTimestamp(startRaw);
    const end = parseIsoToTimestamp(endRaw);
    if (!start || !end) {
      throw new HttpsError(
        "invalid-argument",
        "startDate and endDate are required ISO-8601 strings"
      );
    }
    if (start.toMillis() >= end.toMillis()) {
      throw new HttpsError(
        "invalid-argument",
        "startDate must be strictly before endDate"
      );
    }

    try {
      const allowed = await filterAvailablePropertyIdsForChat({
        propertyIds,
        startDate:
          typeof startRaw === "string" ? startRaw : start.toDate().toISOString(),
        endDate:
          typeof endRaw === "string" ? endRaw : end.toDate().toISOString(),
      });
      // Preserve caller order; drop duplicates silently.
      const seen = new Set<string>();
      const allowedPropertyIds: string[] = [];
      for (const id of propertyIds) {
        if (allowed.has(id) && !seen.has(id)) {
          allowedPropertyIds.push(id);
          seen.add(id);
        }
      }
      return { allowedPropertyIds };
    } catch (err) {
      console.error({
        tag: "filterChatAvailability.error",
        message: err instanceof Error ? err.message : String(err),
        idCount: propertyIds.length,
      });
      throw new HttpsError("internal", "Availability check failed");
    }
  }
);
