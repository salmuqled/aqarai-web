/**
 * عند إنشاء سجل في notification_clicks: يحدّث إجمالي النقرات ويضيف clickCount لسجل الإشعار المقابل.
 */
import * as admin from "firebase-admin";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { FieldValue } from "firebase-admin/firestore";

export const onNotificationClickCreated = onDocumentCreated(
  {
    document: "notification_clicks/{clickId}",
    region: "us-central1",
  },
  async (event) => {
    const snap = event.data;
    if (!snap) return;

    const data = snap.data();
    const notificationId =
      typeof data?.notificationId === "string"
        ? data.notificationId.trim()
        : "";

    const db = admin.firestore();

    await db
      .collection("analytics")
      .doc("notification_totals")
      .set(
        {
          totalClicks: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

    if (notificationId.length > 0 && notificationId.length <= 200) {
      const ref = db.collection("notification_logs").doc(notificationId);
      await db
        .runTransaction(async (tx) => {
          const doc = await tx.get(ref);
          if (!doc.exists) return;
          const d = doc.data()!;
          const sent =
            typeof d.sentCount === "number" ? d.sentCount : 0;
          const prevClicks =
            typeof d.clickCount === "number" ? d.clickCount : 0;
          const newClicks = prevClicks + 1;
          const actualCTR = sent > 0 ? newClicks / sent : 0;
          tx.update(ref, {
            clickCount: newClicks,
            actualCTR,
          });
        })
        .catch(() => undefined);
    }
  }
);
