/**
 * عند إنشاء صفقة مرتبطة بإشعار: يحدّث `notification_logs`
 * (conversionCount / conversionRate / conversionValue عند توفّر مبلغ).
 * لا يُعاد العدّ إلا مرة لكل وثيقة deal (onCreate).
 */
import * as admin from "firebase-admin";
import { onDocumentCreated } from "firebase-functions/v2/firestore";

function num(v: unknown): number {
  if (typeof v === "number" && !Number.isNaN(v)) return v;
  if (typeof v === "string") {
    const x = parseFloat(v);
    return Number.isNaN(x) ? 0 : x;
  }
  return 0;
}

export const onDealCreatedNotificationConversion = onDocumentCreated(
  {
    document: "deals/{dealId}",
    region: "us-central1",
  },
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const data = snap.data();
    const raw = data?.sourceNotificationId;
    const notificationId =
      typeof raw === "string" ? raw.trim() : "";
    if (notificationId.length === 0 || notificationId.length > 200) {
      return;
    }

    const db = admin.firestore();
    const ref = db.collection("notification_logs").doc(notificationId);

    const commission = num(data?.commissionAmount);
    const finalPrice = num(data?.finalPrice);
    const revenueIncrement =
      commission > 0 ? commission : finalPrice > 0 ? finalPrice : 0;

    try {
      await db.runTransaction(async (tx) => {
        const doc = await tx.get(ref);
        if (!doc.exists) return;
        const d = doc.data()!;
        const sent = num(d.sentCount);
        const prevConv = num(d.conversionCount);
        const newConv = prevConv + 1;
        const rate = sent > 0 ? newConv / sent : 0;
        const prevVal = num(d.conversionValue);
        const newVal = prevVal + revenueIncrement;
        const update: Record<string, unknown> = {
          conversionCount: newConv,
          conversionRate: rate,
        };
        if (revenueIncrement > 0) {
          update.conversionValue = newVal;
        }
        tx.update(ref, update);
      });
    } catch (e) {
      console.error("onDealCreatedNotificationConversion", notificationId, e);
    }
  }
);
