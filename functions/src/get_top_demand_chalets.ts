/**
 * Callable: ranks chalet listings by count of **confirmed** bookings in the last 7 days
 * (by `bookings.confirmedAt`).
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

const db = admin.firestore();

function buildPropertyTitle(data: admin.firestore.DocumentData | undefined): string {
  if (!data) return "";
  const t = typeof data.title === "string" ? data.title.trim() : "";
  if (t) return t;
  const area = String(data.areaAr ?? data.area ?? data.areaEn ?? "").trim();
  const typ = String(data.type ?? "").trim();
  if (area && typ) return `${area} • ${typ}`;
  return area || typ || "";
}

function coverFromProperty(data: admin.firestore.DocumentData | undefined): string {
  const images = data?.images;
  if (!Array.isArray(images) || images.length === 0) return "";
  const first = images[0];
  return typeof first === "string" ? first.trim() : "";
}

function isChaletType(data: admin.firestore.DocumentData | undefined): boolean {
  return String(data?.type ?? "")
    .trim()
    .toLowerCase() === "chalet";
}

export const getTopDemandChalets = onCall(
  { region: "us-central1" },
  async () => {
    const cutoff = admin.firestore.Timestamp.fromMillis(
      Date.now() - 7 * 24 * 60 * 60 * 1000
    );

    try {
      const snap = await db
        .collection("bookings")
        .where("status", "==", "confirmed")
        .where("confirmedAt", ">=", cutoff)
        .get();

      const counts = new Map<string, number>();
      for (const doc of snap.docs) {
        const d = doc.data();
        const pid = typeof d.propertyId === "string" ? d.propertyId.trim() : "";
        if (!pid) continue;
        counts.set(pid, (counts.get(pid) ?? 0) + 1);
      }

      const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1]);

      const results: Array<{
        propertyId: string;
        title: string;
        price: number;
        coverImage: string;
        bookingsCount: number;
      }> = [];

      for (const [propertyId, bookingsCount] of sorted) {
        if (results.length >= 10) break;

        const pSnap = await db.collection("properties").doc(propertyId).get();
        if (!pSnap.exists) continue;

        const pd = pSnap.data()!;
        if (!isChaletType(pd)) continue;

        const priceRaw = pd.price;
        const priceNum =
          typeof priceRaw === "number"
            ? priceRaw
            : typeof priceRaw === "string"
              ? Number(priceRaw)
              : Number(priceRaw);

        results.push({
          propertyId,
          title: buildPropertyTitle(pd),
          price: Number.isFinite(priceNum) ? priceNum : 0,
          coverImage: coverFromProperty(pd),
          bookingsCount,
        });
      }

      console.info(
        JSON.stringify({
          tag: "TOP_DEMAND_FETCHED",
          resultsCount: results.length,
        })
      );

      return { ok: true as const, results };
    } catch (err) {
      console.error(
        JSON.stringify({
          tag: "TOP_DEMAND_ERROR",
          message: err instanceof Error ? err.message : String(err),
        })
      );
      throw new HttpsError("internal", "Failed to load top demand chalets");
    }
  }
);
