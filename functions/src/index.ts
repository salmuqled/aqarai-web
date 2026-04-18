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

    const d = (snap.data() || {}) as Record<string, any>;
    const st = String(d.status ?? "active").trim();
    const images = d.images;
    const thumbs = d.thumbnails;
    const imagesLen = Array.isArray(images) ? images.length : 0;
    const thumbsLen = Array.isArray(thumbs) ? thumbs.length : 0;
    const hasAnyImages = imagesLen > 0;

    console.log("[approveListing] before", {
      propertyId,
      status: st,
      approved: d.approved === true,
      hasImage: d.hasImage === true ? true : d.hasImage === false ? false : null,
      imagesLen,
      thumbnailsLen: thumbsLen,
    });

    if (st === "pending_upload") {
      throw new HttpsError(
        "failed-precondition",
        "Owner must upload listing photos before approval (status is pending_upload)."
      );
    }
    if (!hasAnyImages) {
      throw new HttpsError(
        "failed-precondition",
        "Owner must upload listing photos before approval (images is empty)."
      );
    }

    await ref.update({
      approved: true,
      imagesApproved: true,
      // Normalize legacy/inconsistent states: if images exist, hasImage must be true.
      hasImage: true,
      status: "active",
      isActive: true,
      hiddenFromPublic: false,
      approvedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    console.log("[approveListing] after", { propertyId, approved: true });
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
      isActive: false,
      hiddenFromPublic: false,
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
   🔐 تعيين صلاحية أدمن لمستخدم آخر
   Anonymous bootstrap (secret-only) is disabled after initial setup for security:
   only callers with an existing admin session can grant admin. New projects:
   use functions/scripts/set-admin-claim.js + service account, or Firebase Console.
-------------------------------------------------------- */

export const setAdminClaim = onCall({ region: "us-central1" }, async (request) => {
  if (!request.auth) {
    throw new HttpsError(
      "unauthenticated",
      "Sign in required. Anonymous bootstrap for setAdminClaim is disabled for security."
    );
  }
  if (request.auth.token?.admin !== true) {
    throw new HttpsError(
      "permission-denied",
      "Only existing admins can grant admin. Anonymous bootstrap is disabled for security."
    );
  }

  const { targetUid } = (request.data as any) || {};
  if (!targetUid || typeof targetUid !== "string") {
    throw new HttpsError("invalid-argument", "targetUid is required");
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
});

// ⛔️ هذا مكان استيراد أي فانكشن ثانية — خارج كل الفانكشنز
export { approveListingV2 } from "./listing_approval";
export { onPropertyUpdated, onWantedUpdated } from "./match_listings";
export {
  onPropertyAreaSanitizeCreate,
  onPropertyAreaSanitizeUpdate,
} from "./propertyAreaSanitize";
export { onPropertyTerminalStatusGuard } from "./propertyListingTerminalGuard";
export { aqaraiAssistant } from "./assistant";
export {
  aqaraiAgentAnalyze,
  aqaraiAgentCompose,
  aqaraiAgentRankResults,
  aqaraiAgentRankAndCompose,
  aqaraiAgentFindSimilar,
} from "./agent_brain";
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
export {
  dispatchDealFollowUpReminders,
  resetDealFollowUpNotifiedOnNextAtChange,
} from "./dealFollowUpReminders";
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
export { onCompanyPaymentDealFinancialSync } from "./financial/onPaymentConfirmedDealSync";
export {
  addCompanyPaymentAdmin,
  reconcileDealCommissionPaymentTotals,
  getDealCommissionPaymentDiagnostics,
} from "./financial/financialCallables";
export { resendInvoiceEmail, retryInvoicePdf } from "./invoice/invoiceCallables";
export { recreateInvoiceForPayment } from "./invoice/recreateInvoiceForPayment";
export { backfillLedgerForOldInvoices } from "./invoice/invoiceLedgerBackfill";
export { generateBookingInvoice } from "./booking_invoice/generateBookingInvoice";
export {
  createBooking,
  checkBookingAvailability,
  getChaletBusyDateRanges,
  confirmBooking,
  rejectBooking,
  simulateChaletBookingPayment,
  fakePayChaletBooking,
} from "./chalet_booking";
export { cancelExpiredPendingBookings } from "./chalet_booking_expiry_schedule";
export {
  createBookingMyFatoorahPayment,
  verifyBookingMyFatoorahPayment,
  cancelBookingPendingPayment,
} from "./chalet_booking_payment_myfatoorah";
export { getTopDemandChalets } from "./get_top_demand_chalets";
export {
  markChaletBookingTransactionPaid,
  processChaletBookingRefund,
} from "./chalet_booking_finance";
export { onAdminLedgerCreatedFinanceMetrics } from "./adminLedgerFinanceMetrics";

export { featureProperty } from "./featureProperty";
export { featurePropertyMock } from "./featurePropertyMock";
export { featurePropertyPaid } from "./featurePropertyPaid";
export { onFeatureSuggestionEventWritten } from "./aiSuggestionsDailyAgg";
export { autoTuneAiSuggestionsConfig } from "./aiSuggestionsAutoTune";
