/**
 * Scheduled job: reject lots stuck in `pending_admin_review` past [approvalDeadlineAt].
 *
 * Requires composite index: `lots` — `status` ASC, `approvalDeadlineAt` ASC.
 */
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  LOGS,
  LOTS,
  LOT_PENDING_ADMIN_REVIEW,
  LOT_REJECTED,
  readTimestamp,
} from "./auctionFinalizeCore";
import { LOT_REJECTION_APPROVAL_TIMEOUT } from "./auctionRejectionReasons";

const QUERY_LIMIT = 50;

export const rejectExpiredAuctionApprovals = onSchedule(
  {
    region: "us-central1",
    schedule: "every 15 minutes",
    timeZone: "Asia/Kuwait",
    memory: "256MiB",
  },
  async () => {
    const db = admin.firestore();
    const now = Timestamp.now();

    const snap = await db
      .collection(LOTS)
      .where("status", "==", LOT_PENDING_ADMIN_REVIEW)
      .where("approvalDeadlineAt", "<=", now)
      .limit(QUERY_LIMIT)
      .get();

    if (snap.empty) {
      return;
    }

    let processed = 0;
    for (const doc of snap.docs) {
      try {
        await db.runTransaction(async (t) => {
          const fresh = await t.get(doc.ref);
          if (!fresh.exists || !fresh.data()) {
            return;
          }
          const lot = fresh.data()!;
          if (String(lot.status ?? "") !== LOT_PENDING_ADMIN_REVIEW) {
            return;
          }
          const deadline = readTimestamp(lot.approvalDeadlineAt);
          if (!deadline || deadline.toMillis() > Date.now()) {
            return;
          }
          if (lot.adminApproved === true && lot.sellerApprovalStatus === "approved") {
            return;
          }

          const serverNow = FieldValue.serverTimestamp();
          const auctionId = String(lot.auctionId ?? "");

          t.update(doc.ref, {
            status: LOT_REJECTED,
            adminApproved: false,
            rejectionReason: LOT_REJECTION_APPROVAL_TIMEOUT,
            approvalOneHourWarningSent: FieldValue.delete(),
            approvalTenMinWarningSent: FieldValue.delete(),
            approvalOneMinWarningSent: FieldValue.delete(),
            updatedAt: serverNow,
          });

          const logRef = db.collection(LOGS).doc();
          t.set(logRef, {
            auctionId: auctionId || null,
            lotId: doc.id,
            action: "lot_approval_deadline_expired",
            performedBy: "system",
            details: {
              approvalDeadlineAtMillis: deadline.toMillis(),
            },
            timestamp: serverNow,
          });
        });
        processed++;
      } catch (e) {
        logger.warn("rejectExpiredAuctionApprovals: transaction failed", {
          lotId: doc.id,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }

    if (processed > 0) {
      logger.info("rejectExpiredAuctionApprovals: completed", {
        candidates: snap.size,
        processed,
      });
    }
  }
);
