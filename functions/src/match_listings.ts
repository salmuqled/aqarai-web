/**
 * تطابق الإعلانات مع طلبات المطلوب — يُملأ match_logs تلقائياً
 * عند اعتماد إعلان أو طلب مطلوب.
 * (استخدام Firestore triggers من الجيل الأول v1 لتجنب صلاحيات Eventarc)
 */
import * as admin from "firebase-admin";
import * as functions from "firebase-functions/v1";
import { FieldValue } from "firebase-admin/firestore";

const db = admin.firestore();

/** تطبيع النص للمقارنة */
function norm(s: unknown): string {
  if (s == null) return "";
  return String(s).trim().toLowerCase();
}

/** هل الإعلان يطابق طلب المطلوب؟ */
function matches(
  prop: admin.firestore.DocumentData,
  wanted: admin.firestore.DocumentData
): boolean {
  const propType = norm(prop.type);
  const wantedType = norm(wanted.propertyType || wanted.type);
  if (propType !== wantedType) return false;

  const propArea = norm(prop.areaAr || prop.area);
  const wantedArea = norm(wanted.area);
  if (wantedArea && propArea !== wantedArea) return false;

  const propGov = norm(prop.governorateAr || prop.governorate);
  const wantedGov = norm(wanted.governorate);
  if (wantedGov && propGov !== wantedGov) return false;

  const price = typeof prop.price === "number" ? prop.price : Number(prop.price) || 0;
  const minP = wanted.minPrice != null ? Number(wanted.minPrice) : null;
  const maxP = wanted.maxPrice != null ? Number(wanted.maxPrice) : null;
  if (minP != null && !isNaN(minP) && price < minP) return false;
  if (maxP != null && !isNaN(maxP) && price > maxP) return false;

  return true;
}

/** إضافة أو تحديث سجل تطابق واحد (بدون تكرار) */
async function upsertMatchLog(
  propertyId: string,
  wantedId: string,
  propertyData: admin.firestore.DocumentData
): Promise<void> {
  const docId = `${propertyId}_${wantedId}`;
  const price =
    typeof propertyData.price === "number"
      ? propertyData.price
      : Number(propertyData.price) || 0;
  const area =
    propertyData.areaAr ||
    propertyData.areaEn ||
    propertyData.area ||
    propertyData.area_id ||
    "-";

  await db.collection("match_logs").doc(docId).set(
    {
      propertyId,
      wantedId,
      type: propertyData.type || "",
      area,
      area_id: propertyData.areaCode || propertyData.area || "",
      price,
      matchedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
}

/** عند تحديث إعلان: إذا صار معتمداً ونشطاً، ابحث عن طلبات مطلوب مطابقة (v1 trigger) */
export const onPropertyUpdated = functions
  .region("us-central1")
  .firestore.document("properties/{propertyId}")
  .onUpdate(async (change: functions.Change<admin.firestore.QueryDocumentSnapshot>, context: functions.EventContext) => {
    const after = change.after.data();
    if (!after) return;

    if (after.approved !== true || after.status !== "active") return;

    const propertyId = context.params.propertyId as string;
    const wantedsSnap = await db
      .collection("wanted_requests")
      .where("approved", "==", true)
      .limit(300)
      .get();

    let count = 0;
    for (const doc of wantedsSnap.docs) {
      const wantedData = doc.data();
      if (matches(after, wantedData)) {
        await upsertMatchLog(propertyId, doc.id, after);
        count++;
      }
    }
    if (count > 0) {
      console.log(`[match] Property ${propertyId}: ${count} match(es) written.`);
    }
  });

/** عند تحديث طلب مطلوب: إذا صار معتمداً، ابحث عن إعلانات مطابقة (v1 trigger) */
export const onWantedUpdated = functions
  .region("us-central1")
  .firestore.document("wanted_requests/{wantedId}")
  .onUpdate(async (change: functions.Change<admin.firestore.QueryDocumentSnapshot>, context: functions.EventContext) => {
    const after = change.after.data();
    if (!after) return;

    if (after.approved !== true) return;

    const wantedId = context.params.wantedId as string;
    const propsSnap = await db
      .collection("properties")
      .where("approved", "==", true)
      .where("status", "==", "active")
      .limit(300)
      .get();

    let count = 0;
    for (const doc of propsSnap.docs) {
      const propData = doc.data();
      if (matches(propData, after)) {
        await upsertMatchLog(doc.id, wantedId, propData);
        count++;
      }
    }
    if (count > 0) {
      console.log(`[match] Wanted ${wantedId}: ${count} match(es) written.`);
    }
  });
