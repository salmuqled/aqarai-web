/**
 * FCM: notify the previous high bidder when someone places a higher bid.
 * Called only from placeAuctionBid after the transaction succeeds (never inside the txn).
 *
 * FCM data payload (all string values):
 * - type: "auction_outbid"
 * - lotId, auctionId
 */
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";

import { isValidFcmTokenString } from "./fcmToken";

const USERS = "users";

export const OUTBID_NOTIFICATION_TITLE = "تم تجاوزك";
export const OUTBID_NOTIFICATION_BODY =
  "تم تقديم مزايدة أعلى على عقارك";

/**
 * Example FCM v1 JSON (HTTP send) equivalent to what {@link sendAuctionOutbidNotification} builds:
 *
 * ```json
 * {
 *   "message": {
 *     "token": "<users/{recipientUid}.fcmToken>",
 *     "notification": {
 *       "title": "تم تجاوزك",
 *       "body": "تم تقديم مزايدة أعلى على عقارك"
 *     },
 *     "data": {
 *       "type": "auction_outbid",
 *       "lotId": "<lotId>",
 *       "auctionId": "<auctionId>"
 *     },
 *     "android": { "priority": "HIGH" },
 *     "apns": {
 *       "payload": { "aps": { "sound": "default" } }
 *     }
 *   }
 * }
 * ```
 */
export async function sendAuctionOutbidNotification(args: {
  recipientUid: string;
  auctionId: string;
  lotId: string;
}): Promise<void> {
  const { recipientUid, auctionId, lotId } = args;
  const uid = recipientUid.trim();
  if (!uid) return;

  const db = admin.firestore();
  let token: string;
  try {
    const snap = await db.collection(USERS).doc(uid).get();
    const raw = snap.data()?.fcmToken;
    if (typeof raw !== "string" || !isValidFcmTokenString(raw)) {
      return;
    }
    token = raw.trim();
  } catch (e) {
    console.error("[auctionOutbid] read user token failed", uid, e);
    return;
  }

  const data: Record<string, string> = {
    type: "auction_outbid",
    lotId,
    auctionId,
  };

  try {
    await admin.messaging().send({
      token,
      notification: {
        title: OUTBID_NOTIFICATION_TITLE,
        body: OUTBID_NOTIFICATION_BODY,
      },
      data,
      android: {
        priority: "high",
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    });
  } catch (e: unknown) {
    const code =
      e && typeof e === "object" && "code" in e
        ? String((e as { code?: string }).code)
        : String(e);
    console.error("[auctionOutbid] FCM send failed", uid, code);
    if (
      code.includes("registration-token-not-registered") ||
      code.includes("invalid-registration-token")
    ) {
      await db
        .collection(USERS)
        .doc(uid)
        .update({ fcmToken: FieldValue.delete() })
        .catch(() => undefined);
    }
  }
}
