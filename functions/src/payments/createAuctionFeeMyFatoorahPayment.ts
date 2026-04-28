/**
 * Callable: createAuctionFeeMyFatoorahPayment
 *
 * Mirrors the booking flow: server-side mints a hosted-payment-page session
 * for the canonical 100 KWD auction listing fee, returns the URL to load in a
 * WebView, and writes the gateway `paymentId` onto the auction request so the
 * client/webhook can later finalize via `markAuctionFeePaid`.
 *
 *   client → createAuctionFeeMyFatoorahPayment({ requestId })
 *          → MyFatoorah hosted page (in-app WebView)
 *          → user completes payment
 *          → app extracts paymentId → markAuctionFeePaid({ requestId, paymentId })
 *
 * The same `paymentId` is also delivered to `myFatoorahWebhook` for
 * server-to-server confirmation, providing a recovery path when the WebView
 * is dismissed before the deep-link redirect fires.
 */
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";

import {
  myFatoorahExecutePayment,
  myFatoorahInitiatePayment,
  myFatoorahSafeReferenceSegment,
} from "./myfatoorahGateway";
import { myFatoorahApiKey, myFatoorahAppReturnBaseUrl } from "./myfatoorahRuntime";
import { AUCTION_LISTING_FEE_KWD } from "./pricing";

const AUCTION_REQUESTS = "auction_requests";

export const createAuctionFeeMyFatoorahPayment = onCall(
  { region: "us-central1", secrets: [myFatoorahApiKey] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid || typeof uid !== "string" || uid.trim().length === 0) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }

    const data = (request.data ?? {}) as Record<string, unknown>;
    const requestId =
      typeof data.requestId === "string" ? data.requestId.trim() : "";
    if (!requestId) {
      throw new HttpsError("invalid-argument", "requestId is required");
    }
    const langRaw =
      typeof data.lang === "string" ? data.lang.trim().toLowerCase() : "ar";
    const language: "AR" | "EN" = langRaw.startsWith("en") ? "EN" : "AR";

    const db = admin.firestore();
    const requestRef = db.collection(AUCTION_REQUESTS).doc(requestId);
    const snap = await requestRef.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Auction request not found");
    }
    const r = (snap.data() ?? {}) as Record<string, unknown>;
    if (String(r.userId ?? "").trim() !== uid) {
      throw new HttpsError("permission-denied", "Not your auction request");
    }
    const status = String(r.auctionFeeStatus ?? "").trim();
    if (status === "paid") {
      throw new HttpsError("failed-precondition", "Fee already paid");
    }
    if (status !== "pending" && status !== "") {
      throw new HttpsError(
        "failed-precondition",
        `Cannot create payment for fee status ${status}`
      );
    }

    const paymentMethodId = await myFatoorahInitiatePayment(
      AUCTION_LISTING_FEE_KWD
    );
    const gatewayRef = myFatoorahSafeReferenceSegment(`A${requestId}`);
    const appReturn = myFatoorahAppReturnBaseUrl();
    const okQs = new URLSearchParams({
      s: "payment/auction/success",
      requestId,
    });
    const errQs = new URLSearchParams({
      s: "payment/auction/error",
      requestId,
    });
    const { paymentUrl, paymentId, invoiceId } = await myFatoorahExecutePayment(
      {
        amountKwd: AUCTION_LISTING_FEE_KWD,
        paymentMethodId,
        reference: gatewayRef,
        callbackUrl: `${appReturn}?${okQs.toString()}`,
        errorUrl: `${appReturn}?${errQs.toString()}`,
        language,
      }
    );

    await requestRef.update({
      paymentProvider: "myfatoorah",
      paymentSessionId: paymentId,
      paymentSessionInvoiceId: invoiceId,
      paymentSessionUrl: paymentUrl,
      paymentSessionCreatedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    return {
      ok: true,
      requestId,
      paymentUrl,
      paymentId,
      invoiceId,
      amountKwd: AUCTION_LISTING_FEE_KWD,
    };
  }
);
