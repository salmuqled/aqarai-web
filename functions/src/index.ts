// functions/src/index.ts
import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";

admin.initializeApp();

/* --------------------------------------------------------
   Helper: تأكد إن المستخدم أدمن
-------------------------------------------------------- */
function assertAdmin(request: any) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }

  if (request.auth.token.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }

  return request.auth.uid;
}

/* --------------------------------------------------------
   ✅ اعتماد إعلان
-------------------------------------------------------- */
export const approveListing = onCall(
  { region: "us-central1" },
  async (request) => {
    assertAdmin(request);

    const propertyId = request.data?.propertyId;
    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId is required");
    }

    const ref = admin.firestore().collection("properties").doc(propertyId);
    const snap = await ref.get();

    if (!snap.exists) {
      throw new HttpsError("not-found", "Property not found");
    }

    await ref.update({
      approved: true,
      imagesApproved: true,
      status: "active",
      approvedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    return { ok: true };
  }
);

/* --------------------------------------------------------
   ❌ رفض إعلان
-------------------------------------------------------- */
export const rejectListing = onCall(
  { region: "us-central1" },
  async (request) => {
    const adminUid = assertAdmin(request);

    const propertyId = request.data?.propertyId;
    const reason = request.data?.reason ?? "";

    if (!propertyId) {
      throw new HttpsError("invalid-argument", "propertyId is required");
    }

    const ref = admin.firestore().collection("properties").doc(propertyId);
    const snap = await ref.get();

    if (!snap.exists) {
      throw new HttpsError("not-found", "Property not found");
    }

    await ref.update({
      approved: false,
      imagesApproved: false,
      status: "rejected",
      rejected: true,
      rejectedBy: adminUid,
      rejectedReason: reason,
      rejectedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    return { ok: true };
  }
);

/* --------------------------------------------------------
   🔐 تعيين صلاحية أدمن لمستخدم (مرة واحدة فقط)
   استدعِها من التطبيق أو من سكربت مع: targetUid + secret
-------------------------------------------------------- */
const ADMIN_SETUP_SECRET = "aqarai_admin_setup_2025"; // غيّره أو اتركه ثم احذف الاستدعاء بعد الاستخدام

export const setAdminClaim = onCall(
  { region: "us-central1" },
  async (request) => {
    const { targetUid, secret } = (request.data as any) || {};
    if (!targetUid || typeof targetUid !== "string") {
      throw new HttpsError("invalid-argument", "targetUid is required");
    }
    if (secret !== ADMIN_SETUP_SECRET) {
      throw new HttpsError("permission-denied", "Invalid secret");
    }

    await admin.auth().setCustomUserClaims(targetUid, { admin: true });
    await admin
      .firestore()
      .collection("admins")
      .doc(targetUid)
      .set(
        { active: true, updatedAt: FieldValue.serverTimestamp() },
        { merge: true }
      );

    return { ok: true, message: "Admin claim set for " + targetUid };
  }
);

// ⛔️ هذا مكان استيراد أي فانكشن ثانية — خارج كل الفانكشنز
export { approveListingV2 } from "./listing_approval";
export { onPropertyUpdated, onWantedUpdated } from "./match_listings";
export { aqaraiAssistant } from "./assistant";
export { aqaraiAgentAnalyze, aqaraiAgentCompose, aqaraiAgentRankResults, aqaraiAgentFindSimilar } from "./agent_brain";
export { onPropertyCreatedBuyerRadar } from "./buyer_radar";
export { onPropertyUpdatedBuyerNotify } from "./buyer_notifications";
export {
  sendGlobalNotification,
  sendPersonalizedNotifications,
} from "./adminActions";
export { onNotificationClickCreated } from "./notificationTracking";
export { notificationLearningSchedule } from "./notificationLearning";
export { onDealCreatedNotificationConversion } from "./dealConversion";
export {
  queueScheduledNotification,
  dispatchScheduledNotifications,
} from "./scheduledNotifications";
export { updateActivityStats } from "./updateActivityStats";
export { banUser } from "./userModeration";
export { generatePostImage } from "./generatePostImage";
export { generateCarousel } from "./generateCarousel";
export { updateCaptionLearning } from "./updateCaptionLearning";
export { evaluateDecisionOutcome } from "./evaluateDecisionOutcome";
export { evaluateSystemAlerts } from "./evaluateSystemAlerts";
export { placeAuctionBid } from "./placeAuctionBid";
export { finalizeLot } from "./finalizeLot";
export { extendAuctionTime } from "./extendAuctionTime";
export { finalizeExpiredAuctionLots } from "./auctionFinalizeLotsSchedule";
export { rejectExpiredAuctionApprovals } from "./auctionApprovalTimeoutSchedule";
export { notifyAuctionApprovalDeadlineSoon } from "./auctionApprovalPreExpirySchedule";
export { getServerTime } from "./getServerTime";
export { syncPublicLot, backfillPublicLots } from "./syncPublicLot";
export { createAuctionDeposit } from "./createAuctionDeposit";
export { markAuctionFeePaid } from "./markAuctionFeePaid";
export {
  adminReviewAuction,
  sellerApproveAuction,
} from "./auctionPostAuctionReview";
export {
  onCompanyPaymentCreatedLog,
  onCompanyPaymentUpdatedLogStatus,
} from "./companyPaymentLogs";
export { onCompanyPaymentConfirmedInvoice } from "./onCompanyPaymentConfirmedInvoice";
export { resendInvoiceEmail, retryInvoicePdf } from "./invoice/invoiceCallables";
export { backfillLedgerForOldInvoices } from "./invoice/invoiceLedgerBackfill";
