// functions/src/listing_approval.ts

import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * 🔥 اعتماد / رفض الإعلان – النسخة النهائية
 */
export const approveListingV2 = onRequest(
  { region: "us-central1" },
  // 🔴 هنا التعديل الوحيد: إضافة any
  async (req: any, res: any) => {
    try {
      const { id, approved, action, reason } = req.body;

      if (!id || typeof approved !== "boolean" || !action) {
        return res.status(400).json({
          ok: false,
          error: "Missing parameters",
        });
      }

      const ref = db.collection("properties").doc(id);
      const snap = await ref.get();

      if (!snap.exists) {
        return res.status(404).json({
          ok: false,
          error: "Listing not found",
        });
      }

      const data = snap.data() as Record<string, unknown>;

      if (approved === true) {
        const st = String(data["status"] ?? "active");
        if (st === "pending_upload") {
          return res.status(400).json({
            ok: false,
            error:
              "Owner must upload a listing photo before approval (status is pending_upload).",
          });
        }

        const imgs = data["images"];
        const imagesLen = Array.isArray(imgs) ? imgs.length : 0;
        if (imagesLen <= 0) {
          return res.status(400).json({
            ok: false,
            error:
              "Owner must upload a listing photo before approval (images is empty).",
          });
        }
      }

      const now = admin.firestore.FieldValue.serverTimestamp();

      const updateData: any = {
        approved,
        // Display / CRM only — public visibility uses isActive + listingCategory + hiddenFromPublic.
        status: approved ? "active" : "rejected",
        isActive: approved,
        hiddenFromPublic: false,
        updatedAt: now,
      };

      if (approved) {
        // Normalize legacy/inconsistent states: if approved, listing must have images => hasImage true.
        updateData.hasImage = true;
        updateData.approvedAt = now;
      } else {
        updateData.rejectedAt = now;
        updateData.rejectReason = reason ?? "";
      }

      await ref.update(updateData);

      await db.collection("admin_inbox").add({
        type: approved ? "approved" : "rejected",
        listingId: id,
        timestamp: now,
        reason: reason ?? "",
      });

      return res.json({
        ok: true,
        message: approved ? "Listing approved" : "Listing rejected",
      });
    } catch (e: any) {
      return res.status(500).json({
        ok: false,
        error: e.message,
      });
    }
  }
);
