import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";

function assertAdmin(request: { auth?: { uid: string; token?: Record<string, unknown> } }): string {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }
  if (request.auth.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
  return request.auth.uid;
}

/**
 * Disables Firebase Auth (immediate token invalidation path via revoke),
 * merges ban fields into users/{uid} for client-side checks.
 */
export const banUser = onCall({ region: "us-central1" }, async (request) => {
  const adminUid = assertAdmin(request);
  const targetUid = typeof request.data?.targetUid === "string" ? request.data.targetUid.trim() : "";
  if (!targetUid) {
    throw new HttpsError("invalid-argument", "targetUid is required");
  }
  if (targetUid === adminUid) {
    throw new HttpsError("invalid-argument", "Cannot ban yourself");
  }

  let target;
  try {
    target = await admin.auth().getUser(targetUid);
  } catch (e: unknown) {
    const code = (e as { code?: string })?.code;
    if (code === "auth/user-not-found") {
      throw new HttpsError("not-found", "User not found");
    }
    throw e;
  }

  if (target.customClaims && (target.customClaims as { admin?: boolean }).admin === true) {
    throw new HttpsError("permission-denied", "Cannot ban an admin account");
  }

  await admin.auth().updateUser(targetUid, { disabled: true });
  await admin.auth().revokeRefreshTokens(targetUid);

  await admin
    .firestore()
    .collection("users")
    .doc(targetUid)
    .set(
      {
        isBanned: true,
        status: "banned",
        bannedAt: FieldValue.serverTimestamp(),
        bannedBy: adminUid,
      },
      { merge: true }
    );

  return { ok: true };
});
