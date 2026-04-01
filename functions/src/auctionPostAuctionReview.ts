/**
 * Callable: admin approves/rejects deal after auction end (pending_admin_review).
 * Callable: seller approves/rejects highest bid (property owner only).
 * Sale completes only when sellerApprovalStatus === approved AND adminApproved === true.
 */
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";

import { assertAdminClaimAndDirectory } from "./auctionAdminAuth";
import {
  BID_WINNING,
  LOGS,
  LOTS,
  LOT_PENDING_ADMIN_REVIEW,
  LOT_REJECTED,
} from "./auctionFinalizeCore";
import {
  recordAuctionWonAfterSale,
  tryApplySaleCompletionInTransaction,
} from "./auctionSaleCompletion";
import {
  LOT_REJECTION_ADMIN_REJECTED,
  LOT_REJECTION_SELLER_REJECTED,
} from "./auctionRejectionReasons";

function readLotId(data: Record<string, unknown> | undefined): string {
  const lotId = typeof data?.lotId === "string" ? data.lotId.trim() : "";
  if (!lotId) {
    throw new HttpsError("invalid-argument", "lotId is required");
  }
  return lotId;
}

function readDecision(data: Record<string, unknown> | undefined): "approve" | "reject" {
  const d = typeof data?.decision === "string" ? data.decision.trim().toLowerCase() : "";
  if (d === "approve" || d === "reject") return d;
  throw new HttpsError(
    "invalid-argument",
    'decision must be "approve" or "reject"'
  );
}

export const adminReviewAuction = onCall(
  { region: "us-central1" },
  async (request) => {
    const adminUid = await assertAdminClaimAndDirectory(request);
    const data = request.data as Record<string, unknown> | undefined;
    const lotId = readLotId(data);
    const decision = readDecision(data);

    const db = admin.firestore();
    const lotRef = db.collection(LOTS).doc(lotId);
    const winningQuery = lotRef.collection("bids").where("status", "==", BID_WINNING);

    let saleWinner: string | undefined;

    await db.runTransaction(async (t) => {
      const lotSnap = await t.get(lotRef);
      if (!lotSnap.exists || !lotSnap.data()) {
        throw new HttpsError("not-found", "Lot not found");
      }
      const lot = lotSnap.data()!;
      if (String(lot.status ?? "") !== LOT_PENDING_ADMIN_REVIEW) {
        throw new HttpsError(
          "failed-precondition",
          "Lot is not pending admin review"
        );
      }

      const winningSnap = await t.get(winningQuery);
      const now = FieldValue.serverTimestamp();
      const auctionId = String(lot.auctionId ?? "");

      if (decision === "reject") {
        t.update(lotRef, {
          status: LOT_REJECTED,
          adminApproved: false,
          adminDecisionAt: now,
          approvalDeadlineAt: FieldValue.delete(),
          rejectionReason: LOT_REJECTION_ADMIN_REJECTED,
          approvalOneHourWarningSent: FieldValue.delete(),
          approvalTenMinWarningSent: FieldValue.delete(),
          approvalOneMinWarningSent: FieldValue.delete(),
          updatedAt: now,
        });
        const logRef = db.collection(LOGS).doc();
        t.set(logRef, {
          auctionId: auctionId || null,
          lotId,
          action: "admin_rejected_auction_deal",
          performedBy: adminUid,
          details: {},
          timestamp: now,
        });
        return;
      }

      t.update(lotRef, {
        adminApproved: true,
        adminDecisionAt: now,
        updatedAt: now,
      });

      const lotEffective = {
        ...lot,
        adminApproved: true,
      };

      const r = tryApplySaleCompletionInTransaction(
        t,
        db,
        lotRef,
        lotId,
        lotEffective,
        auctionId,
        winningSnap,
        adminUid
      );
      if (r.sold && r.winnerUserId) {
        saleWinner = r.winnerUserId;
      }
    });

    if (saleWinner) {
      recordAuctionWonAfterSale(db, saleWinner, lotId);
    }

    return { ok: true, decision, lotId, sold: Boolean(saleWinner) };
  }
);

export const sellerApproveAuction = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    const uid = request.auth.uid;
    const data = request.data as Record<string, unknown> | undefined;
    const lotId = readLotId(data);
    const decision = readDecision(data);

    const db = admin.firestore();
    const lotRef = db.collection(LOTS).doc(lotId);
    const winningQuery = lotRef.collection("bids").where("status", "==", BID_WINNING);

    let saleWinner: string | undefined;

    await db.runTransaction(async (t) => {
      const lotSnap = await t.get(lotRef);
      if (!lotSnap.exists || !lotSnap.data()) {
        throw new HttpsError("not-found", "Lot not found");
      }
      const lot = lotSnap.data()!;
      if (String(lot.status ?? "") !== LOT_PENDING_ADMIN_REVIEW) {
        throw new HttpsError(
          "failed-precondition",
          "Lot is not pending seller/admin review"
        );
      }

      const propertyIdRaw = lot.propertyId;
      const propertyId =
        propertyIdRaw != null && String(propertyIdRaw).trim() !== ""
          ? String(propertyIdRaw).trim()
          : "";
      if (!propertyId) {
        throw new HttpsError(
          "failed-precondition",
          "Lot has no propertyId; seller cannot approve"
        );
      }

      const propRef = db.collection("properties").doc(propertyId);
      const propSnap = await t.get(propRef);
      if (!propSnap.exists || !propSnap.data()) {
        throw new HttpsError("not-found", "Property not found for lot");
      }
      const ownerId = propSnap.data()!.ownerId;
      if (String(ownerId ?? "") !== uid) {
        throw new HttpsError(
          "permission-denied",
          "Only the property owner can respond"
        );
      }

      const winningSnap = await t.get(winningQuery);
      const now = FieldValue.serverTimestamp();
      const auctionId = String(lot.auctionId ?? "");

      if (decision === "reject") {
        t.update(lotRef, {
          sellerApprovalStatus: "rejected",
          sellerApprovalAt: now,
          status: LOT_REJECTED,
          adminApproved: false,
          approvalDeadlineAt: FieldValue.delete(),
          rejectionReason: LOT_REJECTION_SELLER_REJECTED,
          approvalOneHourWarningSent: FieldValue.delete(),
          approvalTenMinWarningSent: FieldValue.delete(),
          approvalOneMinWarningSent: FieldValue.delete(),
          updatedAt: now,
        });
        const logRef = db.collection(LOGS).doc();
        t.set(logRef, {
          auctionId: auctionId || null,
          lotId,
          action: "seller_rejected_auction_deal",
          performedBy: uid,
          details: {},
          timestamp: now,
        });
        return;
      }

      t.update(lotRef, {
        sellerApprovalStatus: "approved",
        sellerApprovalAt: now,
        updatedAt: now,
      });

      const lotEffective = {
        ...lot,
        sellerApprovalStatus: "approved",
        adminApproved: lot.adminApproved === true,
      };

      const r = tryApplySaleCompletionInTransaction(
        t,
        db,
        lotRef,
        lotId,
        lotEffective,
        auctionId,
        winningSnap,
        uid
      );
      if (r.sold && r.winnerUserId) {
        saleWinner = r.winnerUserId;
      }
    });

    if (saleWinner) {
      recordAuctionWonAfterSale(db, saleWinner, lotId);
    }

    return { ok: true, decision, lotId, sold: Boolean(saleWinner) };
  }
);
