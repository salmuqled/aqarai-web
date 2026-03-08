/**
 * Buyer Radar: when a new property is created, count how many buyers
 * in buyer_interests match (areaCode, type, serviceType) and store
 * interestedBuyersCount + buyerDemandDetected on the property.
 * No notifications — demand detection only.
 */
import * as admin from "firebase-admin";
import { onDocumentCreated } from "firebase-functions/v2/firestore";

const db = admin.firestore();

export const onPropertyCreatedBuyerRadar = onDocumentCreated(
  {
    document: "properties/{propertyId}",
    region: "us-central1",
  },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot?.exists) return;

    const propertyId = event.params?.propertyId;
    if (!propertyId) return;

    const data = snapshot.data();
    const areaCode = data?.areaCode != null ? String(data.areaCode).trim() : null;
    const type = data?.type != null ? String(data.type).trim() : null;
    const serviceType = data?.serviceType != null ? String(data.serviceType).trim() : null;

    if (!areaCode && !type && !serviceType) return;

    let query = db.collection("buyer_interests") as admin.firestore.Query;

    if (areaCode) query = query.where("areaCode", "==", areaCode);
    if (type) query = query.where("type", "==", type);
    if (serviceType) query = query.where("serviceType", "==", serviceType);

    const matchSnap = await query.get();
    const count = matchSnap.size;

    const propertyRef = db.collection("properties").doc(propertyId);
    await propertyRef.update({
      interestedBuyersCount: count,
      buyerDemandDetected: count > 0,
    });
  }
);
