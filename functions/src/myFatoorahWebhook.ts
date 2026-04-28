/**
 * MyFatoorah → AqarAi server-to-server webhook.
 *
 * Trigger: configure the URL of this Cloud Function as a webhook target on
 * the MyFatoorah portal. Add the shared-secret header (e.g. `x-mf-secret`)
 * and the matching env var `MYFATOORAH_WEBHOOK_SECRET` on the Functions
 * runtime.
 *
 * Responsibility: handle a 'Success' notification by performing the SAME
 * server-side `GetPaymentStatus` verification that the app-side path uses
 * (`verifyBookingMyFatoorahPayment`), then routing the verified payment to
 * the correct finalizer (booking, featured ad, auction fee).
 *
 * Idempotency: every webhook delivery is keyed by `payment_webhooks/{key}`
 * where `key` = paymentId (or invoiceId fallback). Duplicate deliveries
 * short-circuit with `200` and no Firestore writes.
 *
 * Response policy: once authentication succeeds we ALWAYS respond `200` so
 * MyFatoorah does not retry indefinitely on data we cannot route. Routing
 * failures are logged + persisted to `payment_webhooks` for triage.
 */
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";

import { myFatoorahGetPaymentStatus } from "./payments/myfatoorahVerify";
import { myFatoorahApiKey } from "./payments/myfatoorahRuntime";
import {
  finalizeBookingAfterPayment,
  type BookingStatus,
} from "./chalet_booking";
import { AUCTION_LISTING_FEE_KWD, featurePlanFor } from "./payments/pricing";

const myFatoorahWebhookSecret = defineSecret("MYFATOORAH_WEBHOOK_SECRET");

const db = admin.firestore();

interface ExtractedKeys {
  paymentId: string | null;
  invoiceId: string | null;
  customerReference: string | null;
}

function strOrNull(v: unknown): string | null {
  if (v == null) return null;
  const s = String(v).trim();
  return s.length > 0 ? s : null;
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

/**
 * MyFatoorah does not publish a single canonical webhook envelope: payloads
 * vary across portal versions and account types. We accept the union and
 * pull whichever identifier is present.
 */
function extractWebhookKeys(body: unknown): ExtractedKeys {
  if (!body || typeof body !== "object") {
    return { paymentId: null, invoiceId: null, customerReference: null };
  }
  const root = body as Record<string, unknown>;
  const data = (root.Data ?? root.data) as Record<string, unknown> | undefined;

  const paymentId =
    strOrNull(data?.PaymentId) ??
    strOrNull(root.PaymentId) ??
    strOrNull(data?.paymentId) ??
    strOrNull(root.paymentId);

  const invoiceId =
    strOrNull(data?.InvoiceId) ??
    strOrNull(root.InvoiceId) ??
    strOrNull(data?.invoiceId) ??
    strOrNull(root.invoiceId);

  const customerReference =
    strOrNull(data?.CustomerReference) ??
    strOrNull(root.CustomerReference) ??
    strOrNull(data?.UserDefinedField) ??
    strOrNull(root.UserDefinedField);

  return { paymentId, invoiceId, customerReference };
}

interface RouteOutcome {
  routed: "booking" | "feature" | "auction" | "none";
  detail: string;
}

/**
 * Look up the booking matching this paymentId. Bookings store the gateway
 * paymentId on the booking doc (set by `createBookingMyFatoorahPayment`), so
 * a single Firestore query is enough.
 */
async function findBookingByPaymentId(
  paymentId: string
): Promise<{ id: string; clientId: string; status: BookingStatus } | null> {
  const q = await db
    .collection("bookings")
    .where("paymentId", "==", paymentId)
    .limit(1)
    .get();
  if (q.empty) return null;
  const doc = q.docs[0];
  const data = doc.data();
  return {
    id: doc.id,
    clientId: typeof data.clientId === "string" ? data.clientId.trim() : "",
    status: (typeof data.status === "string"
      ? data.status.trim()
      : "") as BookingStatus,
  };
}

async function routeToBooking(
  paymentId: string,
  verifiedAmountKwd: number,
  verifiedStatus: string
): Promise<RouteOutcome | null> {
  const booking = await findBookingByPaymentId(paymentId);
  if (!booking) return null;

  if (!booking.clientId) {
    return {
      routed: "booking",
      detail: `booking ${booking.id} missing clientId`,
    };
  }

  if (booking.status === "confirmed") {
    return {
      routed: "booking",
      detail: `booking ${booking.id} already confirmed`,
    };
  }

  // Pull the booking again to confirm totalPrice matches verified amount
  // (defense-in-depth — finalizeBookingAfterPayment also validates).
  const bookingSnap = await db.collection("bookings").doc(booking.id).get();
  const totalPriceRaw = bookingSnap.data()?.totalPrice;
  const totalPrice =
    typeof totalPriceRaw === "number" && Number.isFinite(totalPriceRaw)
      ? totalPriceRaw
      : 0;
  if (totalPrice <= 0 || round3(totalPrice) !== round3(verifiedAmountKwd)) {
    return {
      routed: "booking",
      detail: `amount mismatch: booking=${totalPrice} verified=${verifiedAmountKwd}`,
    };
  }

  await finalizeBookingAfterPayment(booking.id, {
    kind: "myfatoorah",
    uid: booking.clientId,
    paymentId,
    paymentGatewayStatus: verifiedStatus,
  });
  return { routed: "booking", detail: `booking ${booking.id} confirmed` };
}

async function routeToFeature(
  paymentId: string,
  verifiedAmountKwd: number
): Promise<RouteOutcome | null> {
  // Feature payments are claimed via `payment_logs/{paymentId}` by
  // `featurePropertyPaid` (callable). The webhook's job for features is
  // therefore informational only — we cannot reconstruct (propertyId,
  // durationDays) without the original request. Mark a pending claim only
  // if the amount matches a known plan.
  const plan = (() => {
    for (const p of [3, 7, 14, 30]) {
      const candidate = featurePlanFor(p, round3(verifiedAmountKwd));
      if (candidate) return candidate;
    }
    return null;
  })();
  if (!plan) return null;

  const claimRef = db.collection("payment_logs").doc(paymentId);
  const existing = await claimRef.get();
  if (existing.exists) {
    return {
      routed: "feature",
      detail: `feature paymentId already claimed`,
    };
  }
  // Do not finalize a feature ad from the webhook alone (no propertyId
  // mapping). Just record the verified gateway notification so admin
  // tooling can reconcile.
  await db
    .collection("payment_webhooks_unclaimed_features")
    .doc(paymentId)
    .set({
      paymentId,
      amountKwd: round3(verifiedAmountKwd),
      currency: "KWD",
      receivedAt: FieldValue.serverTimestamp(),
      hint: "Awaiting featurePropertyPaid to claim with propertyId+durationDays",
    });
  return {
    routed: "feature",
    detail: `feature ${verifiedAmountKwd} KWD recorded; awaiting client claim`,
  };
}

async function routeToAuctionFee(
  paymentId: string,
  verifiedAmountKwd: number,
  verifiedStatus: string
): Promise<RouteOutcome | null> {
  if (round3(verifiedAmountKwd) !== round3(AUCTION_LISTING_FEE_KWD)) {
    return null;
  }

  // We need a `requestId` to flip auction_requests. The app sets
  // `paymentId` on the auction_request alongside `auctionFeeStatus:
  // "pending"` once the user starts checkout. Look it up.
  const q = await db
    .collection("auction_requests")
    .where("paymentId", "==", paymentId)
    .limit(1)
    .get();
  if (q.empty) {
    // Stash for admin reconciliation; client will still complete the flow
    // via `markAuctionFeePaid`.
    await db
      .collection("payment_webhooks_unclaimed_auction")
      .doc(paymentId)
      .set({
        paymentId,
        amountKwd: round3(verifiedAmountKwd),
        currency: "KWD",
        receivedAt: FieldValue.serverTimestamp(),
        hint: "Awaiting markAuctionFeePaid to claim with requestId",
      });
    return {
      routed: "auction",
      detail: `auction paymentId received; awaiting client claim`,
    };
  }

  const requestDoc = q.docs[0];
  const requestId = requestDoc.id;
  const data = requestDoc.data();
  const userId = typeof data.userId === "string" ? data.userId.trim() : "";
  const status = String(data.auctionFeeStatus ?? "");
  if (status === "paid") {
    return {
      routed: "auction",
      detail: `auction request ${requestId} already paid`,
    };
  }

  const claimRef = db.collection("payment_logs").doc(paymentId);
  const requestRef = db.collection("auction_requests").doc(requestId);

  await db.runTransaction(async (tx) => {
    const [reqSnap, claimSnap] = await Promise.all([
      tx.get(requestRef),
      tx.get(claimRef),
    ]);
    if (claimSnap.exists) return;
    if (!reqSnap.exists) return;
    const cur = reqSnap.data()!;
    if (String(cur.auctionFeeStatus ?? "") !== "pending") return;

    tx.update(requestRef, {
      auctionFeeStatus: "paid",
      auctionFeePaidAt: FieldValue.serverTimestamp(),
      auctionFee: AUCTION_LISTING_FEE_KWD,
      paymentReference: paymentId,
      paymentGatewayStatus: verifiedStatus,
      updatedAt: FieldValue.serverTimestamp(),
    });

    tx.set(claimRef, {
      paymentId,
      action: "auction_fee_payment",
      newStatus: "success",
      performedBy: userId || "myfatoorah_webhook",
      timestamp: FieldValue.serverTimestamp(),
      verified: true,
      gateway: "MyFatoorah",
      paymentMode: "production",
      relatedType: "auction_request",
      relatedId: requestId,
      amountKwd: AUCTION_LISTING_FEE_KWD,
      currency: "KWD",
      source: "webhook",
    });
  });

  return {
    routed: "auction",
    detail: `auction request ${requestId} confirmed via webhook`,
  };
}

export const myFatoorahWebhook = onRequest(
  {
    region: "us-central1",
    secrets: [myFatoorahWebhookSecret, myFatoorahApiKey],
    timeoutSeconds: 60,
    memory: "256MiB",
    cors: false,
  },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send("Method Not Allowed");
      return;
    }

    // Shared-secret authentication. Configure the secret value in MyFatoorah
    // portal as an extra request header. We accept either a custom header
    // (`x-mf-secret`) or `Authorization: Bearer <secret>` — different MF
    // portal versions emit different shapes.
    const expected = (myFatoorahWebhookSecret.value() ?? "").trim();
    if (!expected) {
      console.error("[myFatoorahWebhook] secret not configured");
      res.status(500).send("Webhook secret not configured");
      return;
    }
    const headerSecret =
      typeof req.header("x-mf-secret") === "string"
        ? req.header("x-mf-secret")!.trim()
        : "";
    const authHeader =
      typeof req.header("authorization") === "string"
        ? req.header("authorization")!.trim()
        : "";
    const bearer = authHeader.toLowerCase().startsWith("bearer ")
      ? authHeader.slice(7).trim()
      : "";
    const provided = headerSecret || bearer;
    if (provided !== expected) {
      console.warn(
        JSON.stringify({
          tag: "myFatoorahWebhook.unauthorized",
          hasHeaderSecret: headerSecret.length > 0,
          hasBearer: bearer.length > 0,
        })
      );
      res.status(401).send("Unauthorized");
      return;
    }

    const body: unknown = req.body;
    const keys = extractWebhookKeys(body);

    if (!keys.paymentId && !keys.invoiceId) {
      console.warn(
        JSON.stringify({
          tag: "myFatoorahWebhook.no_keys",
          bodyType: typeof body,
        })
      );
      res.status(200).send({ ok: true, ignored: "no_keys" });
      return;
    }

    // Idempotency claim: keyed by paymentId (preferred) or invoiceId.
    const idempotencyKey = keys.paymentId ?? keys.invoiceId!;
    const eventRef = db.collection("payment_webhooks").doc(idempotencyKey);
    let alreadySeen = false;
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(eventRef);
        if (snap.exists) {
          alreadySeen = true;
          return;
        }
        tx.set(eventRef, {
          paymentId: keys.paymentId,
          invoiceId: keys.invoiceId,
          customerReference: keys.customerReference,
          receivedAt: FieldValue.serverTimestamp(),
          processed: false,
        });
      });
    } catch (err) {
      console.error(
        "[myFatoorahWebhook] idempotency tx failed",
        err instanceof Error ? err.message : err
      );
      res.status(200).send({ ok: true, ignored: "idempotency_failed" });
      return;
    }
    if (alreadySeen) {
      res.status(200).send({ ok: true, duplicate: true });
      return;
    }

    if (!keys.paymentId) {
      // Without a paymentId we cannot call GetPaymentStatus by PaymentId.
      // Stash + 200 — admin reconciliation only.
      await eventRef.set(
        {
          processed: true,
          processedAt: FieldValue.serverTimestamp(),
          outcome: "no_payment_id",
        },
        { merge: true }
      );
      res.status(200).send({ ok: true, ignored: "no_payment_id" });
      return;
    }

    // Verify with the gateway server-side. Never trust the webhook body.
    let verified;
    try {
      verified = await myFatoorahGetPaymentStatus(keys.paymentId);
    } catch (err) {
      console.error(
        "[myFatoorahWebhook] verification failed",
        err instanceof Error ? err.message : err
      );
      await eventRef.set(
        {
          processed: true,
          processedAt: FieldValue.serverTimestamp(),
          outcome: "verification_error",
          error: err instanceof Error ? err.message : String(err),
        },
        { merge: true }
      );
      res.status(200).send({ ok: true, ignored: "verification_error" });
      return;
    }

    if (!verified.ok) {
      await eventRef.set(
        {
          processed: true,
          processedAt: FieldValue.serverTimestamp(),
          outcome: "not_paid",
          gatewayStatus: verified.status,
        },
        { merge: true }
      );
      res.status(200).send({ ok: true, ignored: "not_paid" });
      return;
    }
    if ((verified.currency ?? "").toUpperCase() !== "KWD") {
      await eventRef.set(
        {
          processed: true,
          processedAt: FieldValue.serverTimestamp(),
          outcome: "wrong_currency",
          currency: verified.currency,
        },
        { merge: true }
      );
      res.status(200).send({ ok: true, ignored: "wrong_currency" });
      return;
    }
    if (verified.amountKwd == null) {
      await eventRef.set(
        {
          processed: true,
          processedAt: FieldValue.serverTimestamp(),
          outcome: "missing_amount",
        },
        { merge: true }
      );
      res.status(200).send({ ok: true, ignored: "missing_amount" });
      return;
    }

    let outcome: RouteOutcome | null = null;
    try {
      outcome = await routeToBooking(
        keys.paymentId,
        verified.amountKwd,
        verified.status
      );
      if (!outcome) {
        outcome = await routeToAuctionFee(
          keys.paymentId,
          verified.amountKwd,
          verified.status
        );
      }
      if (!outcome) {
        outcome = await routeToFeature(keys.paymentId, verified.amountKwd);
      }
    } catch (err) {
      console.error(
        "[myFatoorahWebhook] routing failed",
        err instanceof Error ? err.message : err
      );
      await eventRef.set(
        {
          processed: true,
          processedAt: FieldValue.serverTimestamp(),
          outcome: "routing_error",
          error: err instanceof Error ? err.message : String(err),
        },
        { merge: true }
      );
      res.status(200).send({ ok: true, ignored: "routing_error" });
      return;
    }

    await eventRef.set(
      {
        processed: true,
        processedAt: FieldValue.serverTimestamp(),
        outcome: outcome?.routed ?? "no_match",
        detail: outcome?.detail ?? "no matching collection for paymentId",
        verifiedAmountKwd: round3(verified.amountKwd),
        verifiedStatus: verified.status,
      },
      { merge: true }
    );

    console.info(
      JSON.stringify({
        tag: "myFatoorahWebhook.processed",
        paymentId: keys.paymentId,
        invoiceId: keys.invoiceId,
        outcome: outcome?.routed ?? "no_match",
        detail: outcome?.detail ?? null,
      })
    );

    res.status(200).send({ ok: true });
  }
);
