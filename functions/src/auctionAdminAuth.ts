/**
 * Auction admin callables: Firebase custom claim `admin: true` + `admins/{uid}` (active !== false).
 */
import * as admin from "firebase-admin";
import { HttpsError } from "firebase-functions/v2/https";

const ADMINS = "admins";

export async function assertAdminClaimAndDirectory(request: {
  auth?: { uid: string; token?: Record<string, unknown> };
}): Promise<string> {
  if (!request.auth?.uid) {
    throw new HttpsError("unauthenticated", "Authentication required");
  }
  if (request.auth.token?.["admin"] !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
  const uid = request.auth.uid;
  const dir = await admin.firestore().collection(ADMINS).doc(uid).get();
  if (!dir.exists) {
    throw new HttpsError(
      "permission-denied",
      "Admin account is not listed in the admins directory"
    );
  }
  const active = dir.data()?.["active"];
  if (active === false) {
    throw new HttpsError(
      "permission-denied",
      "Admin directory entry is inactive"
    );
  }
  return uid;
}
