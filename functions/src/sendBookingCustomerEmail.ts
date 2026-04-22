/**
 * Firestore trigger: email the CUSTOMER a confirmation when a booking flips
 * to `status: "confirmed"`.
 *
 * RUNS ONCE per confirmation. Idempotency is enforced by the booking's own
 * `customerEmailSent` flag — if it's already true at invocation time, we
 * return immediately.
 *
 * NON-NEGOTIABLES
 *   - Never sends on `pending_payment`, `cancelled`, `rejected`, or any
 *     non-`confirmed` status. The confirmed transition is the only path.
 *   - Never crashes. All network/SMTP errors are caught and logged; the
 *     function returns normally so the runtime does not retry.
 *   - Never modifies booking business data (status, dates, prices, ledger
 *     fields). Writes are confined to `customerEmailSent`,
 *     `customerEmailSentAt`, `customerEmailAttemptAt`, `customerEmailError`,
 *     and `customerEmailStatus` ("sent" | "failed"). The status field exists
 *     so ops dashboards can filter `where("customerEmailStatus", "==",
 *     "failed")` without having to interpret the absence of a boolean.
 *   - Reuses the project-wide SMTP pipeline ([invoiceSmtpRuntime] +
 *     `INVOICE_SMTP_PASS` secret) so there's a single source of truth for
 *     App Password rotation.
 */
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { defineSecret, defineString } from "firebase-functions/params";
import { FieldValue } from "firebase-admin/firestore";
import nodemailer from "nodemailer";

import { INVOICE_BRAND } from "./invoice/constants";
import {
  resolveInvoiceSmtp,
  logInvoiceSmtpDiagnostics,
} from "./invoice/invoiceSmtpRuntime";

const invoiceSmtpPass = defineSecret("INVOICE_SMTP_PASS");
const invoiceSmtpHost = defineString("INVOICE_SMTP_HOST", {
  default: "smtp.gmail.com",
});
const invoiceSmtpPort = defineString("INVOICE_SMTP_PORT", { default: "465" });

/**
 * App-wide support number shown in the footer of the confirmation email.
 * Update here if support routing changes — this is the only place it lives
 * for customer-facing confirmation emails. Leave as an empty string to
 * opt out and use [FALLBACK_SUPPORT_LINE_AR] instead (the footer will
 * render a short Arabic text directing the user to support inside the app).
 */
const SUPPORT_PHONE = "+965 9999 0000";

/** Shown when [chaletName] is missing on the property doc. Per spec. */
const FALLBACK_CHALET_NAME_AR = "الشاليه";

/** Shown when [SUPPORT_PHONE] is empty/missing. Keeps the footer line
 *  intact so the email never renders a blank or broken row. */
const FALLBACK_SUPPORT_LINE_AR = "تواصل مع الدعم عبر التطبيق";

const EMAIL_SUBJECT = "تم تأكيد حجزك 🎉";

/** Cap a free-form error message before writing it to Firestore so we
 *  never blow up a booking doc with a 5 KB stack trace. Also strips
 *  newlines so the value displays cleanly in the console. */
function sanitizeErrorMessage(raw: unknown): string {
  const s = raw instanceof Error ? raw.message : String(raw ?? "");
  return s.replace(/\s+/g, " ").trim().slice(0, 300);
}

interface ResolvedCustomerPayload {
  bookingId: string;
  chaletName: string;
  startDate: string;
  endDate: string;
  nights: number;
  totalPrice: string; // already formatted "X.XXX"
  clientEmail: string;
  googleMapsLink: string | null; // null → button is hidden in the template
  supportPhone: string;
}

/** Format a Firestore Timestamp as Asia/Kuwait `dd/MM/yyyy`. */
function formatKuwaitDate(ts: admin.firestore.Timestamp): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Kuwait",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(ts.toDate());
}

/** Format a KWD amount as "X.XXX" (3 decimals, no currency suffix). */
function formatKwdAmount(raw: unknown): string {
  const n = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(n)) return "0.000";
  return (Math.round(n * 1000) / 1000).toFixed(3);
}

/** Escape HTML entities in user-supplied strings that land in the template. */
function escapeHtml(input: string): string {
  return input
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Build the Google Maps link for the chalet. Preference order:
 *   1. Property doc explicit URL fields (if the project ever adds them).
 *   2. A Google Maps search URL derived from the Arabic area/governorate.
 *   3. null — the template will hide the button entirely.
 *
 * This is intentionally a best-effort derivation: we never want to block
 * the email on missing location data.
 */
function buildGoogleMapsLink(
  propertyData: Record<string, unknown> | null
): string | null {
  if (!propertyData) return null;

  const explicit =
    (typeof propertyData.googleMapsLink === "string"
      ? propertyData.googleMapsLink.trim()
      : "") ||
    (typeof propertyData.mapUrl === "string"
      ? propertyData.mapUrl.trim()
      : "") ||
    (typeof propertyData.locationUrl === "string"
      ? propertyData.locationUrl.trim()
      : "");
  if (explicit.startsWith("http")) return explicit;

  const areaAr =
    typeof propertyData.areaArabic === "string"
      ? propertyData.areaArabic.trim()
      : "";
  const govAr =
    typeof propertyData.governorateArabic === "string"
      ? propertyData.governorateArabic.trim()
      : "";

  const parts = [areaAr, govAr, "الكويت"].filter((s) => s.length > 0);
  if (parts.length === 0) return null;

  const query = encodeURIComponent(parts.join(" "));
  return `https://www.google.com/maps/search/?api=1&query=${query}`;
}

/** Render the customer confirmation HTML. Matches the spec template exactly,
 *  with escaping applied to every interpolated value. The map button is
 *  hidden when no link is available. */
function renderConfirmationHtml(p: ResolvedCustomerPayload): string {
  const chaletName = escapeHtml(p.chaletName);
  const startDate = escapeHtml(p.startDate);
  const endDate = escapeHtml(p.endDate);
  const nights = String(p.nights);
  const totalPrice = escapeHtml(p.totalPrice);
  const bookingId = escapeHtml(p.bookingId);
  // Support line: render the phone if provided; otherwise a clean Arabic
  // sentence so the footer row never appears empty/broken.
  const trimmedPhone = p.supportPhone.trim();
  const supportLine = escapeHtml(
    trimmedPhone.length > 0 ? trimmedPhone : FALLBACK_SUPPORT_LINE_AR
  );

  // Hide the button entirely when we don't have a real URL — never render
  // an empty anchor tag.
  const hasMapsLink =
    typeof p.googleMapsLink === "string" &&
    p.googleMapsLink.trim().length > 0;
  const mapsButton = hasMapsLink
    ? `<a href="${escapeHtml(p.googleMapsLink!.trim())}"
       style="display:block;background:#0A84FF;color:#fff;padding:12px;text-align:center;border-radius:8px;text-decoration:none;">
       📍 عرض الموقع على الخريطة
    </a>`
    : "";

  return `<!DOCTYPE html>
<html lang="ar" dir="rtl">
<body style="font-family:Arial;background:#f6f7fb;padding:20px;">
  <div style="max-width:600px;background:#fff;margin:auto;padding:24px;border-radius:12px;">

    <h2>🎉 تم تأكيد حجزك بنجاح</h2>

    <p><b>اسم الشاليه:</b> ${chaletName}</p>
    <p><b>تاريخ الدخول:</b> ${startDate}</p>
    <p><b>تاريخ الخروج:</b> ${endDate}</p>
    <p><b>عدد الليالي:</b> ${nights}</p>
    <p><b>السعر الإجمالي:</b> ${totalPrice} د.ك</p>
    <p><b>حالة الدفع:</b> تم الدفع ✅</p>
    <p><b>رقم الحجز:</b> ${bookingId}</p>

    ${mapsButton}

    <p style="margin-top:20px;">
      💬 لأي استفسار: ${supportLine}
    </p>

  </div>
</body>
</html>`;
}

/** Resolve the client's email. Auth record wins; `users/{uid}.email` is a
 *  fallback for accounts created/linked outside of Auth. */
async function resolveClientEmail(clientId: string): Promise<string | null> {
  // Auth is authoritative — it's verified and cannot be spoofed client-side.
  try {
    const u = await admin.auth().getUser(clientId);
    if (u.email && u.email.includes("@")) return u.email.trim();
  } catch {
    // fall through to Firestore fallback
  }
  try {
    const snap = await admin.firestore().collection("users").doc(clientId).get();
    const d = snap.data();
    if (d && typeof d.email === "string" && d.email.includes("@")) {
      return d.email.trim();
    }
  } catch {
    // ignore
  }
  return null;
}

/** Fetch property doc once and extract the fields we need for the email. */
async function resolvePropertyBits(
  propertyId: string
): Promise<{
  chaletName: string;
  googleMapsLink: string | null;
}> {
  try {
    const snap = await admin
      .firestore()
      .collection("properties")
      .doc(propertyId)
      .get();
    const d = snap.data() ?? null;
    const raw =
      d && typeof d.chaletName === "string" ? d.chaletName.trim() : "";
    // Fall back to a generic Arabic label when the owner didn't name it.
    const chaletName = raw.length > 0 ? raw : FALLBACK_CHALET_NAME_AR;
    const googleMapsLink = buildGoogleMapsLink(d);
    return { chaletName, googleMapsLink };
  } catch (err) {
    logger.warn("sendBookingCustomerEmail.property_read_failed", {
      propertyId,
      error: sanitizeErrorMessage(err),
    });
    return {
      chaletName: FALLBACK_CHALET_NAME_AR,
      googleMapsLink: null,
    };
  }
}

export const sendBookingCustomerEmail = onDocumentUpdated(
  {
    document: "bookings/{bookingId}",
    region: "us-central1",
    secrets: [invoiceSmtpPass],
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (event) => {
    const bookingId = event.params.bookingId;
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!after) return;

    // --- TRIGGER GUARDS ---------------------------------------------------
    // Must be a clean pending -> confirmed transition. Anything else
    // (cancellations, price edits, metadata updates) is ignored.
    const beforeStatus =
      typeof before?.status === "string" ? before!.status.trim() : "";
    const afterStatus =
      typeof after.status === "string" ? after.status.trim() : "";
    if (afterStatus !== "confirmed") return;
    if (beforeStatus === "confirmed") return;

    // Fast-path idempotency check. The post-send write below is what
    // actually persists this flag; this read just avoids wasted work on
    // obvious re-entries (e.g. manual admin re-triggers).
    if (after.customerEmailSent === true) {
      logger.info("sendBookingCustomerEmail.skip.already_sent", { bookingId });
      return;
    }

    // --- LOAD DATA ---------------------------------------------------------
    const propertyId =
      typeof after.propertyId === "string" ? after.propertyId : "";
    const clientId =
      typeof after.clientId === "string" ? after.clientId : "";
    const startTs = after.startDate as admin.firestore.Timestamp | undefined;
    const endTs = after.endDate as admin.firestore.Timestamp | undefined;
    const daysCount =
      typeof after.daysCount === "number" ? after.daysCount : null;

    if (
      !propertyId ||
      !clientId ||
      !(startTs instanceof admin.firestore.Timestamp) ||
      !(endTs instanceof admin.firestore.Timestamp) ||
      daysCount == null ||
      daysCount <= 0
    ) {
      logger.warn("sendBookingCustomerEmail.skip.missing_fields", {
        bookingId,
        hasPropertyId: !!propertyId,
        hasClientId: !!clientId,
        hasStart: startTs instanceof admin.firestore.Timestamp,
        hasEnd: endTs instanceof admin.firestore.Timestamp,
        daysCount,
      });
      return;
    }

    const [clientEmail, propertyBits] = await Promise.all([
      resolveClientEmail(clientId),
      resolvePropertyBits(propertyId),
    ]);

    if (!clientEmail) {
      logger.warn("sendBookingCustomerEmail.skip.no_client_email", {
        bookingId,
        clientId,
      });
      // Record a non-fatal marker so ops can see why this booking didn't
      // receive a confirmation email. Never retry on this — the customer
      // simply doesn't have an email on file. Using the structured
      // "failed" status here makes the booking show up in the same ops
      // filter as real SMTP failures.
      try {
        await event.data!.after.ref.update({
          customerEmailStatus: "failed",
          customerEmailAttemptAt: FieldValue.serverTimestamp(),
          customerEmailError: "no_client_email",
        });
      } catch {
        // swallow — logs already explain
      }
      return;
    }

    const payload: ResolvedCustomerPayload = {
      bookingId,
      chaletName: propertyBits.chaletName,
      startDate: formatKuwaitDate(startTs),
      endDate: formatKuwaitDate(endTs),
      nights: daysCount,
      totalPrice: formatKwdAmount(after.totalPrice),
      clientEmail,
      googleMapsLink: propertyBits.googleMapsLink,
      supportPhone: SUPPORT_PHONE,
    };

    // --- SMTP SEND ---------------------------------------------------------
    const smtp = resolveInvoiceSmtp(
      invoiceSmtpHost.value(),
      invoiceSmtpPort.value(),
      invoiceSmtpPass.value()
    );
    logInvoiceSmtpDiagnostics("sendBookingCustomerEmail", smtp);

    const smtpUser = smtp.user.trim();
    const smtpPass = smtp.pass.trim().replace(/\s+/g, "");
    if (!smtpUser || !smtpPass) {
      logger.error("sendBookingCustomerEmail.smtp_not_configured", {
        bookingId,
      });
      // Same non-fatal marker pattern: visible to ops without retry storm.
      try {
        await event.data!.after.ref.update({
          customerEmailStatus: "failed",
          customerEmailAttemptAt: FieldValue.serverTimestamp(),
          customerEmailError: "smtp_not_configured",
        });
      } catch {
        // swallow
      }
      return;
    }

    const html = renderConfirmationHtml(payload);

    try {
      const transporter = nodemailer.createTransport({
        host: smtp.host.trim(),
        port: smtp.port,
        secure: smtp.port === 465,
        auth: { user: smtpUser, pass: smtpPass },
      });

      await transporter.sendMail({
        from: `"${INVOICE_BRAND.appName}" <${smtpUser}>`,
        to: clientEmail.toLowerCase(),
        subject: EMAIL_SUBJECT,
        html,
      });

      // Commit the idempotency flag only on real SMTP success. This is the
      // single gate that prevents double-sends on future re-entries.
      // `customerEmailStatus: "sent"` gives ops a single indexable field to
      // filter on; `customerEmailSent: true` stays as the idempotency gate
      // that's already checked at function entry.
      await event.data!.after.ref.update({
        customerEmailStatus: "sent",
        customerEmailSent: true,
        customerEmailAttemptAt: FieldValue.serverTimestamp(),
        customerEmailSentAt: FieldValue.serverTimestamp(),
        customerEmailError: FieldValue.delete(),
      });

      logger.info("sendBookingCustomerEmail.sent", {
        bookingId,
        clientEmail,
      });
    } catch (err) {
      const msg = sanitizeErrorMessage(err);
      logger.error("sendBookingCustomerEmail.send_failed", {
        bookingId,
        error: msg,
      });
      // Mark the attempt but do NOT set `customerEmailSent`. That boolean
      // remains the single idempotency gate — leaving it unset allows a
      // future manual resend admin callable to retry this booking. We
      // deliberately do NOT auto-retry from here (spec §6).
      try {
        await event.data!.after.ref.update({
          customerEmailStatus: "failed",
          customerEmailAttemptAt: FieldValue.serverTimestamp(),
          customerEmailError: msg,
        });
      } catch {
        // Even the patch failed; we already logged the primary error.
      }
    }
  }
);
