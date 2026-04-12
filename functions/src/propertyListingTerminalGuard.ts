/**
 * Keeps properties.status + sold aligned with properties.dealStatus:
 * terminal sold/rented/exchanged is only valid when dealStatus === "closed".
 *
 * Logic must stay in sync with functions/scripts/propertyStatusCleanup.mjs
 */

import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { onDocumentWritten } from "firebase-functions/v2/firestore";

const TERMINAL = ["sold", "rented", "exchanged"] as const;

export type TerminalCorrection = {
  newStatus: string;
  newSold: boolean;
  reason: string;
};

/** When deal is not closed, sold is never true. When closed, true only for sale listings. */
export function computeSoldForPropertyDoc(data: Record<string, unknown>): boolean {
  const dealStatus = String(data.dealStatus ?? "").trim();
  if (dealStatus !== "closed") return false;
  const svc = String(data.serviceType ?? "sale").toLowerCase().trim();
  return svc === "sale";
}

/**
 * If document has invalid terminal lifecycle (sold/rented/exchanged without closed deal),
 * returns safe status + sold. Otherwise null.
 *
 * CASE order (images are the only signal for media — do not use hasImage):
 * 1. No images → pending_upload
 * 2. Else not approved → pending_approval
 * 3. Else approved + images → active
 * 4. Else → active
 */
export function correctionForInvalidTerminalStatus(
  data: Record<string, unknown>
): TerminalCorrection | null {
  const status = String(data.status ?? "").trim();
  const dealStatus = String(data.dealStatus ?? "").trim();
  if (!TERMINAL.includes(status as (typeof TERMINAL)[number])) return null;
  if (dealStatus === "closed") return null;

  const approved = data.approved === true;
  const imgs = data.images;
  const imagesLen = Array.isArray(imgs) ? imgs.length : 0;
  const hasImages = imagesLen > 0;

  let newStatus: string;
  let reason: string;

  if (!hasImages) {
    newStatus = "pending_upload";
    reason = "CASE_1_no_images";
  } else if (!approved) {
    newStatus = "pending_approval";
    reason = "CASE_2_unapproved";
  } else if (approved && hasImages) {
    newStatus = "active";
    reason = "CASE_3_approved_with_images";
  } else {
    newStatus = "active";
    reason = "CASE_4_fallback";
  }

  const newSold = computeSoldForPropertyDoc({
    ...data,
    status: newStatus,
    dealStatus,
  });

  return { newStatus, newSold, reason };
}

export const onPropertyTerminalStatusGuard = onDocumentWritten(
  {
    document: "properties/{propertyId}",
    region: "us-central1",
  },
  async (event) => {
    const before = event.data?.before;
    const after = event.data?.after;
    if (!after?.exists) return;

    const propertyId = String(event.params.propertyId ?? "");

    if (before?.exists) {
      const b = before.data() as Record<string, unknown> | undefined;
      const a = after.data() as Record<string, unknown> | undefined;
      if (b && a) {
        const bs = String(b.status ?? "").trim();
        const as = String(a.status ?? "").trim();
        const bd = String(b.dealStatus ?? "").trim();
        const ad = String(a.dealStatus ?? "").trim();
        const terminalStatuses: readonly string[] = TERMINAL;
        const isTerminal = terminalStatuses.includes(as);
        const isInvalid = isTerminal && ad !== "closed";
        if (bs === as && bd === ad && !isInvalid) {
          console.log(
            JSON.stringify({
              event: "property_terminal_status_guard",
              propertyId,
              oldStatus: as,
              dealStatus: ad || null,
              actionTaken: "skipped",
            })
          );
          return;
        }
      }
    }

    const data = after.data() as Record<string, unknown>;
    const fix = correctionForInvalidTerminalStatus(data);
    if (!fix) return;

    const curStatus = String(data.status ?? "").trim();
    const curSold = data.sold === true;

    if (fix.newStatus === curStatus && fix.newSold === curSold) return;

    await admin.firestore().collection("properties").doc(propertyId).update({
      status: fix.newStatus,
      sold: fix.newSold,
      updatedAt: FieldValue.serverTimestamp(),
    });

    const imagesLen = Array.isArray(data.images) ? data.images.length : 0;
    console.log(
      JSON.stringify({
        event: "property_terminal_status_autocorrect",
        propertyId,
        oldStatus: curStatus,
        newStatus: fix.newStatus,
        dealStatus: String(data.dealStatus ?? "").trim() || null,
        approved: data.approved === true,
        imagesLen,
        reason: fix.reason,
        actionTaken: "updated",
      })
    );
  }
);
