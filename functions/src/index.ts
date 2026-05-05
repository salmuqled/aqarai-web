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

/* --------------------------------------------------------
   Daily rental property search (callable; optional date availability)
-------------------------------------------------------- */
const SEARCH_DAILY_PROPERTIES_PAGE_SIZE = 20;
const SEARCH_DAILY_MAX_SCAN_PAGES = 40;

// Availability primitives are owned by `./shared_availability`. Re-import the
// ones this file still references so the only runtime dependency on them is a
// single import (no duplicated overlap math anywhere else in the codebase).
import {
  parseIsoToTimestamp as parseSearchDailyDateInput,
  fetchUnavailablePropertyIdsBatched as fetchUnavailablePropertyIdsSearchDaily,
} from "./shared_availability";

type SearchDailyPropertyKind = "any" | "apartment" | "chalet";

function normalizeSearchDailyPropertyKind(raw: unknown): SearchDailyPropertyKind {
  if (typeof raw !== "string") return "any";
  const p = raw.trim().toLowerCase();
  if (p === "apartment") return "apartment";
  if (p === "chalet") return "chalet";
  return "any";
}

function buildSearchDailyBaseQuery(
  db: admin.firestore.Firestore,
  rentalType: "daily" | "monthly",
  propertyKind: SearchDailyPropertyKind
): admin.firestore.Query {
  let q: admin.firestore.Query = db
    .collection("properties")
    .where("serviceType", "==", "rent")
    .where("rentalType", "==", rentalType)
    .where("approved", "==", true)
    .where("isActive", "==", true);

  if (propertyKind === "apartment") {
    q = q.where("type", "==", "apartment");
  } else if (propertyKind === "chalet") {
    q = q.where("type", "==", "chalet");
  }

  return q
    .orderBy("createdAt", "desc")
    .orderBy(admin.firestore.FieldPath.documentId(), "desc");
}

function computeSearchDailyScore(
  data: admin.firestore.DocumentData,
  nowMs: number
): number {
  let score = 0;

  const createdAt = data.createdAt;
  if (createdAt instanceof admin.firestore.Timestamp) {
    const ageDays = (nowMs - createdAt.toMillis()) / (1000 * 60 * 60 * 24);
    score += Math.max(0, 30 - ageDays);
  }

  const featuredFlag = data.featured === true || data.featured === "true";
  const featuredUntil = data.featuredUntil;
  const featuredActive =
    featuredUntil instanceof admin.firestore.Timestamp &&
    featuredUntil.toMillis() > nowMs;
  if (featuredFlag || featuredActive) {
    score += 20;
  }

  const price = data.price;
  if (typeof price === "number" && price > 0) {
    score += 5;
  } else if (typeof price === "string" && price.trim() !== "") {
    const n = Number(price);
    if (!Number.isNaN(n) && n > 0) score += 5;
  }

  return score;
}

export const searchDailyProperties = onCall(
  { region: "us-central1" },
  async (request) => {
    console.log("🔥🔥 FUNCTION HIT 🔥🔥");
    try {
      console.log("DEBUG_REQUEST_DATA:", JSON.stringify(request.data));
      const db = admin.firestore();
      const {
        startDate,
        endDate,
        cursor,
        rentalType: rentalTypeRaw,
        propertyKind: propertyKindRaw,
      } = (request.data || {}) as {
        startDate?: unknown;
        endDate?: unknown;
        cursor?: unknown;
        rentalType?: unknown;
        propertyKind?: unknown;
      };

      let rentalType: "daily" | "monthly" = "daily";
      if (typeof rentalTypeRaw === "string") {
        const t = rentalTypeRaw.trim().toLowerCase();
        if (t === "monthly") rentalType = "monthly";
        else if (t === "daily") rentalType = "daily";
      }

      const propertyKind = normalizeSearchDailyPropertyKind(propertyKindRaw);

      console.log("DEBUG_RENTAL_TYPE:", rentalType);

      const rawCursor = typeof cursor === "string" ? cursor : "";
      const reqStartTs = parseSearchDailyDateInput(startDate);
      const reqEndTs = parseSearchDailyDateInput(endDate);
      const filterByDates =
        reqStartTs != null && reqEndTs != null && reqStartTs.toMillis() < reqEndTs.toMillis();

      if (
        (startDate != null && startDate !== "" && reqStartTs == null) ||
        (endDate != null && endDate !== "" && reqEndTs == null)
      ) {
        throw new HttpsError("invalid-argument", "Invalid startDate or endDate");
      }
      if (
        (reqStartTs != null && reqEndTs == null) ||
        (reqStartTs == null && reqEndTs != null)
      ) {
        throw new HttpsError(
          "invalid-argument",
          "startDate and endDate must both be provided for availability filtering"
        );
      }
      if (reqStartTs != null && reqEndTs != null && reqStartTs.toMillis() >= reqEndTs.toMillis()) {
        throw new HttpsError("invalid-argument", "startDate must be before endDate");
      }

      let q = buildSearchDailyBaseQuery(db, rentalType, propertyKind);

      if (rawCursor.length > 0) {
        let payload: { createdAtMs?: unknown; documentId?: unknown };
        try {
          payload = JSON.parse(
            Buffer.from(rawCursor, "base64").toString("utf8")
          ) as { createdAtMs?: unknown; documentId?: unknown };
        } catch {
          throw new HttpsError("invalid-argument", "Invalid cursor");
        }
        const documentId =
          typeof payload.documentId === "string" ? payload.documentId : "";
        if (!documentId) {
          throw new HttpsError("invalid-argument", "Invalid cursor");
        }
        const msRaw = payload.createdAtMs;
        const ms =
          typeof msRaw === "number" && Number.isFinite(msRaw)
            ? msRaw
            : typeof msRaw === "string" && msRaw.length > 0
              ? Number(msRaw)
              : NaN;
        const ts = Number.isFinite(ms)
          ? admin.firestore.Timestamp.fromMillis(ms as number)
          : admin.firestore.Timestamp.fromMillis(0);
        q = q.startAfter(ts, documentId);
      }

      console.log("DEBUG_QUERY_FILTER:", {
        serviceType: "rent",
        rentalType: rentalType,
        propertyKind,
      });

      const pageSize = SEARCH_DAILY_PROPERTIES_PAGE_SIZE;
      const nowMs = Date.now();
      const collected: FirebaseFirestore.QueryDocumentSnapshot[] = [];
      let lastSnap: FirebaseFirestore.QuerySnapshot | null = null;
      let pages = 0;

      while (collected.length < pageSize && pages < SEARCH_DAILY_MAX_SCAN_PAGES) {
        pages += 1;
        const snap = await q.limit(pageSize).get();
        lastSnap = snap;
        const snapshot = snap;
        console.log("🔥 QUERY RENTAL TYPE:", rentalType);
        console.log(
          "🔥 DB RETURN TYPES:",
          snapshot.docs.map((d) => ({
            id: d.id,
            rentalType: d.data().rentalType,
          }))
        );
        console.log("DEBUG_RAW_DOCS_COUNT:", snapshot.size);
        console.log(
          "DEBUG_RAW_RENTAL_TYPES:",
          snapshot.docs.map((d) => d.data().rentalType)
        );
        if (snap.empty) break;

        const ids = snap.docs.map((d) => d.id);
        const unavailable = filterByDates
          ? await fetchUnavailablePropertyIdsSearchDaily(
              db,
              ids,
              reqStartTs!,
              reqEndTs!,
              nowMs
            )
          : new Set<string>();

        for (const doc of snap.docs) {
          if (!filterByDates || !unavailable.has(doc.id)) {
            collected.push(doc);
            if (collected.length >= pageSize) break;
          }
        }

        if (collected.length >= pageSize) break;
        if (snap.size < pageSize) break;

        const lastDoc = snap.docs[snap.docs.length - 1];
        const dLast = lastDoc.data();
        const ca = (dLast as { createdAt?: admin.firestore.Timestamp }).createdAt;
        if (!(ca instanceof admin.firestore.Timestamp)) break;
        q = buildSearchDailyBaseQuery(db, rentalType, propertyKind).startAfter(
          ca,
          lastDoc.id
        );
      }

      const availableDocs = collected.slice(0, pageSize);
      availableDocs.sort((a, b) => {
        const sa = computeSearchDailyScore(a.data(), nowMs);
        const sb = computeSearchDailyScore(b.data(), nowMs);
        if (sb !== sa) return sb - sa;
        return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
      });

      console.log("DEBUG_FILTERED_COUNT:", availableDocs.length);
      console.log(
        "DEBUG_FILTERED_RENTAL_TYPES:",
        availableDocs.map((d) => d.data().rentalType)
      );

      const results = availableDocs.map((doc) => ({
        id: doc.id,
        ...doc.data(),
      }));

      console.log("DEBUG_RESPONSE_COUNT:", results.length);

      const lastBatch = lastSnap;
      const hitScanCap = pages >= SEARCH_DAILY_MAX_SCAN_PAGES;
      const hasMore =
        !hitScanCap && lastBatch != null && lastBatch.size === pageSize;
      const lastForCursor =
        lastBatch != null && lastBatch.docs.length > 0
          ? lastBatch.docs[lastBatch.docs.length - 1]
          : null;

      let nextCursor: string | null = null;
      if (hasMore && lastForCursor) {
        const data = lastForCursor.data() ?? {};
        const payload = {
          createdAtMs:
            (data as { createdAt?: admin.firestore.Timestamp }).createdAt
              ?.toMillis?.() || null,
          documentId: lastForCursor.id,
        };
        nextCursor = Buffer.from(JSON.stringify(payload), "utf8").toString(
          "base64"
        );
      }

      return {
        success: true,
        properties: results,
        hasMore,
        nextCursor,
      };
    } catch (error) {
      if (error instanceof HttpsError) throw error;
      console.error("searchDailyProperties error:", error);
      throw new HttpsError("internal", "Failed to fetch properties");
    }
  }
);

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
export { aqaraiAgentComputeRoi } from "./roi_engine";
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
export { onBookingConfirmedNotifyOwner } from "./bookingConfirmedOwnerNotification";
export { cleanupLegacyPendingBookings } from "./cleanup_legacy_pending_bookings";
export { sendBookingCustomerEmail } from "./sendBookingCustomerEmail";
export { sendBookingOwnerEmail } from "./sendBookingOwnerEmail";
export { sendBookingAdminEmail } from "./sendBookingAdminEmail";
export {
  createBookingMyFatoorahPayment,
  verifyBookingMyFatoorahPayment,
  cancelBookingPendingPayment,
} from "./chalet_booking_payment_myfatoorah";
export { myFatoorahWebhook } from "./myFatoorahWebhook";
export { createAuctionFeeMyFatoorahPayment } from "./payments/createAuctionFeeMyFatoorahPayment";
export { createFeaturePropertyMyFatoorahPayment } from "./payments/createFeaturePropertyMyFatoorahPayment";
export { myFatoorahAppReturn } from "./payments/myfatoorahAppReturn";
export { getTopDemandChalets } from "./get_top_demand_chalets";
export { filterChatAvailability } from "./chat_availability";
export { generateChatSmartSuggestions } from "./smart_suggestions";
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
