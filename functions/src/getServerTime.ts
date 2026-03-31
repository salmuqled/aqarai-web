/**
 * Callable: returns authoritative server wall time (ms) for client clock sync.
 * Requires a signed-in user (abuse / quota control).
 */
import { onCall, HttpsError } from "firebase-functions/v2/https";

export const getServerTime = onCall({ region: "us-central1" }, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }
  return { nowMs: Date.now() };
});
