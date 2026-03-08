/**
 * Smart Buyer Notification: runs when a property is updated and
 * buyerDemandDetected transitions from false to true (set by Buyer Radar).
 * Sends FCM to matching buyers. One per user (no duplicates).
 * Data payload: propertyId.
 */
import * as admin from "firebase-admin";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";

const db = admin.firestore();
const messaging = admin.messaging();

const NOTIFICATION_TITLE = "عقار جديد يطابق بحثك";

function buildBody(areaLabel: string): string {
  return `تم إضافة عقار جديد في ${areaLabel} قد يناسبك. اضغط لمشاهدة التفاصيل.`;
}

export const onPropertyUpdatedBuyerNotify = onDocumentUpdated(
  {
    document: "properties/{propertyId}",
    region: "us-central1",
  },
  async (event) => {
    const change = event.data;
    if (!change) return;

    const before = change.before.data();
    const after = change.after.data();

    const beforeDemand = before?.buyerDemandDetected === true;
    const afterDemand = after?.buyerDemandDetected === true;

    if (beforeDemand || !afterDemand) return;

    const propertyId = event.params?.propertyId;
    if (!propertyId) return;

    const data = after;
    const areaCode = data?.areaCode != null ? String(data.areaCode).trim() : null;
    const type = data?.type != null ? String(data.type).trim() : null;
    const serviceType = data?.serviceType != null ? String(data.serviceType).trim() : null;

    if (!areaCode && !type && !serviceType) return;

    let query = db.collection("buyer_interests") as admin.firestore.Query;
    if (areaCode) query = query.where("areaCode", "==", areaCode);
    if (type) query = query.where("type", "==", type);
    if (serviceType) query = query.where("serviceType", "==", serviceType);

    const matchSnap = await query.get();
    if (matchSnap.empty) return;

    const areaLabel = data?.areaAr ?? data?.areaEn ?? areaCode ?? "منطقتك";
    const body = buildBody(areaLabel);
    const sentUserIds = new Set<string>();

    for (const doc of matchSnap.docs) {
      const userId = doc.data()?.userId;
      if (!userId || typeof userId !== "string" || sentUserIds.has(userId)) continue;

      let fcmToken: string | null = null;
      try {
        const userSnap = await db.collection("users").doc(userId).get();
        fcmToken = userSnap.data()?.fcmToken ?? null;
        if (typeof fcmToken !== "string" || !fcmToken.trim()) continue;
      } catch {
        continue;
      }

      try {
        await messaging.send({
          token: fcmToken,
          notification: {
            title: NOTIFICATION_TITLE,
            body,
          },
          data: {
            propertyId,
          },
          android: {
            priority: "high",
          },
          apns: {
            payload: { aps: { sound: "default" } },
            fcmOptions: {},
          },
        });
        sentUserIds.add(userId);
      } catch {
        // skip failed send; do not retry to avoid duplicate
      }
    }
  }
);
