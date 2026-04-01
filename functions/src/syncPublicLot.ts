/**
 * Mirrors safe catalog fields from `lots` → `public_lots` for unauthenticated clients.
 * Does not copy bids, bidders, deposits, or internal notes.
 */
import * as admin from "firebase-admin";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";

const db = () => admin.firestore();

/** Map internal `pending` to public `upcoming`; other statuses unchanged. */
function toPublicStatus(raw: string): string {
  const s = raw.trim();
  if (s === "pending") return "upcoming";
  return s;
}

/**
 * Safe payload for `public_lots/{lotId}` (id === lotId).
 * Optionally includes `propertyId` when present on the source lot (listing link only).
 */
export function buildPublicLotData(
  lotId: string,
  d: admin.firestore.DocumentData
): Record<string, unknown> {
  const rawStatus = String(d.status ?? "pending");
  const status = toPublicStatus(rawStatus);

  const sp = d.startingPrice;
  const mi = d.minIncrement;
  const startingPrice =
    typeof sp === "number" && Number.isFinite(sp)
      ? sp
      : typeof sp === "string"
        ? parseFloat(sp) || 0
        : 0;
  const minIncrement =
    typeof mi === "number" && Number.isFinite(mi)
      ? mi
      : typeof mi === "string"
        ? parseFloat(mi) || 0
        : 0;

  const img = d.image;
  const image =
    img != null && String(img).trim() !== "" ? String(img).trim() : null;
  const loc = d.location;
  const location =
    loc != null && String(loc).trim() !== "" ? String(loc).trim() : null;

  const pid = d.propertyId;
  const propertyId =
    pid != null && String(pid).trim() !== "" ? String(pid).trim() : null;

  const dv = d.depositValue;
  const depositValue =
    typeof dv === "number" && Number.isFinite(dv)
      ? dv
      : typeof dv === "string"
        ? parseFloat(dv) || 0
        : 0;
  const depositType =
    typeof d.depositType === "string" && d.depositType.trim() !== ""
      ? d.depositType.trim()
      : "fixed";

  const endsAt = d.endsAt ?? d.endTime ?? null;
  const currentHighBid =
    d.currentHighBid !== undefined && d.currentHighBid !== null
      ? d.currentHighBid
      : d.highestBid;
  const currentHighBidderId =
    d.currentHighBidderId != null && String(d.currentHighBidderId).trim() !== ""
      ? String(d.currentHighBidderId).trim()
      : d.highestBidderId != null && String(d.highestBidderId).trim() !== ""
        ? String(d.highestBidderId).trim()
        : null;
  const bidCount =
    typeof d.bidCount === "number" && Number.isFinite(d.bidCount)
      ? d.bidCount
      : 0;

  const out: Record<string, unknown> = {
    id: lotId,
    auctionId: String(d.auctionId ?? ""),
    title: String(d.title ?? ""),
    image,
    location,
    startingPrice,
    minIncrement,
    depositType,
    depositValue,
    startTime: d.startTime ?? admin.firestore.Timestamp.now(),
    status,
    currentHighBid: currentHighBid ?? null,
    currentHighBidderId,
    bidCount,
  };
  if (endsAt != null) {
    out.endsAt = endsAt;
  }
  if (propertyId != null) {
    out.propertyId = propertyId;
  }

  const sas = d.sellerApprovalStatus;
  if (typeof sas === "string" && sas.trim() !== "") {
    out.sellerApprovalStatus = sas.trim();
  }
  if (d.adminApproved === true || d.adminApproved === false) {
    out.adminApproved = d.adminApproved;
  }
  const saa = d.sellerApprovalAt;
  if (saa != null) {
    out.sellerApprovalAt = saa;
  }
  const ada = d.adminDecisionAt;
  if (ada != null) {
    out.adminDecisionAt = ada;
  }
  const adl = d.approvalDeadlineAt;
  if (adl != null) {
    out.approvalDeadlineAt = adl;
  }
  const rr = d.rejectionReason;
  if (typeof rr === "string" && rr.trim() !== "") {
    out.rejectionReason = rr.trim();
  }
  return out;
}

export const syncPublicLot = onDocumentWritten(
  {
    document: "lots/{lotId}",
    region: "us-central1",
  },
  async (event) => {
    const lotId = event.params.lotId as string;
    const pubRef = db().collection("public_lots").doc(lotId);
    const change = event.data;
    if (!change) return;

    if (!change.after.exists) {
      await pubRef.delete().catch(() => undefined);
      return;
    }

    const data = change.after.data();
    if (!data) return;

    await pubRef.set(buildPublicLotData(lotId, data), { merge: true });
  }
);

function assertAdmin(request: { auth?: { token?: Record<string, unknown> } }): void {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Authentication required");
  }
  if (request.auth.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
}

/** One-time / repair: rebuild all `public_lots` from `lots`. */
export const backfillPublicLots = onCall({ region: "us-central1" }, async (request) => {
  assertAdmin(request);
  const snap = await db().collection("lots").get();
  let written = 0;
  for (const doc of snap.docs) {
    await db()
      .collection("public_lots")
      .doc(doc.id)
      .set(buildPublicLotData(doc.id, doc.data()), { merge: true });
    written++;
  }
  return { ok: true, count: written };
});
