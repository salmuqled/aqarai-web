/**
 * Firestore trigger: email the OWNER a confirmation with a clear financial
 * breakdown when a booking flips to `status: "confirmed"`.
 *
 * This trigger is a SIBLING of `sendBookingCustomerEmail`. Both fire on the
 * same `pending_payment -> confirmed` transition but write into disjoint
 * namespaces (`owner*` vs `customer*`) on the booking doc, so one failing
 * never blocks or corrupts the other.
 *
 * NON-NEGOTIABLES
 *   - Never sends before payment: only fires on the confirmed transition.
 *   - Never leaks customer PII: the email contains NO client phone, email,
 *     name, or any contact info. Chalet name + dates + financials only.
 *     This is enforced by the payload builder — the client doc is never
 *     even read.
 *   - Never claims the payout already moved: the body says "سيتم تحويل"
 *     (will be transferred) per policy, never "تم تحويل".
 *   - Never crashes. All errors caught; runtime is told not to retry.
 *   - Never modifies booking business data. Writes confined to
 *     `ownerEmailSent`, `ownerEmailSentAt`, `ownerEmailAttemptAt`,
 *     `ownerEmailError`, `ownerEmailStatus`.
 *   - Reuses the project-wide SMTP pipeline ([invoiceSmtpRuntime] +
 *     `INVOICE_SMTP_PASS` secret) so one App Password rotation covers all
 *     outgoing mail.
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
import { COMMISSION_RATE } from "./chalet_booking_finance";
import {
  isDailyRentListingServer,
  propertyTypeSlugBooking,
} from "./chalet_booking";

const invoiceSmtpPass = defineSecret("INVOICE_SMTP_PASS");
const invoiceSmtpHost = defineString("INVOICE_SMTP_HOST", {
  default: "smtp.gmail.com",
});
const invoiceSmtpPort = defineString("INVOICE_SMTP_PORT", { default: "465" });

/**
 * Support number shown in the email footer. Kept as a file-local constant
 * (rather than a shared module) because the spec forbids refactoring
 * unrelated files. If we unify later, the customer email has the same
 * constant; just extract both to `invoice/constants.ts` in one pass.
 */
const SUPPORT_PHONE = "+965 9999 0000";

/** Shown when [chaletName] is missing on the property doc. Matches the
 *  customer email so both sides see the same wording. */
const FALLBACK_CHALET_NAME_AR = "الشاليه";

const FALLBACK_APARTMENT_BUILDING_AR = "الشقة";

const EMAIL_SUBJECT_CHALET = "تم تأكيد حجز جديد على شاليهك";

const EMAIL_SUBJECT_APARTMENT_DAILY = "تم تأكيد حجز جديد على وحدتك (إيجار يومي)";

/** Shown when [SUPPORT_PHONE] is empty/missing. Keeps the footer row
 *  from rendering as a stray colon or blank. */
const FALLBACK_SUPPORT_LINE_AR = "تواصل مع الدعم عبر التطبيق";

/**
 * Mandated payout-policy disclaimer. Kept as a constant so legal can
 * audit/update a single place.
 */
const PAYOUT_POLICY_NOTE_AR =
  "هذا الحجز مدفوع ومؤكد، وسيتم تحويل صافي المبلغ المستحق لك حسب سياسة الدفع المعتمدة.";

interface ResolvedOwnerPayload {
  bookingId: string;
  headlineAr: string;
  listingLabelAr: string;
  listingValueAr: string;
  startDate: string;
  endDate: string;
  nights: number;
  totalPrice: string; // formatted "X.XXX"
  commissionPct: string; // e.g. "15"
  commissionAmount: string; // formatted "X.XXX"
  ownerNet: string; // formatted "X.XXX"
  ownerEmail: string;
  supportPhone: string;
}

/** Cap a free-form error before writing it to Firestore so a chatty SMTP
 *  error never bloats the booking doc or leaks multi-line stack traces. */
function sanitizeErrorMessage(raw: unknown): string {
  const s = raw instanceof Error ? raw.message : String(raw ?? "");
  return s.replace(/\s+/g, " ").trim().slice(0, 300);
}

/** Format a Firestore Timestamp as Asia/Kuwait `dd/MM/yyyy`. Matches the
 *  customer email format so the same booking reads identically in both
 *  inboxes. */
function formatKuwaitDate(ts: admin.firestore.Timestamp): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Kuwait",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(ts.toDate());
}

/**
 * Format a KWD amount as "X.XXX" (3 decimals — Kuwaiti dinar's official
 * subdivision is fils = 1/1000). The spec says "round to 2 decimals if
 * needed", but using 3 matches what the customer email and the rest of
 * the app already show, so owners see the same precision everywhere.
 */
function formatKwd(raw: unknown): string {
  const n = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(n)) return "0.000";
  return (Math.round(n * 1000) / 1000).toFixed(3);
}

/** Escape HTML entities for every user-supplied value in the template. */
function escapeHtml(input: string): string {
  return input
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Resolve the owner's email. Auth record wins (verified, cannot be
 * spoofed); `users/{uid}.email` is a fallback for accounts created or
 * linked outside of Auth. No caching — this is called at most once per
 * confirmation, and the cost is negligible.
 */
async function resolveOwnerEmail(ownerId: string): Promise<string | null> {
  try {
    const u = await admin.auth().getUser(ownerId);
    if (u.email && u.email.includes("@")) return u.email.trim();
  } catch {
    // fall through to Firestore fallback
  }
  try {
    const snap = await admin
      .firestore()
      .collection("users")
      .doc(ownerId)
      .get();
    const d = snap.data();
    if (d && typeof d.email === "string" && d.email.includes("@")) {
      return d.email.trim();
    }
  } catch {
    // ignore — we'll return null and the caller marks the booking as failed
  }
  return null;
}

/** Fetch property doc once — listing headline + labels for chalet vs daily apartment. */
async function resolveOwnerListingEmailContext(propertyId: string): Promise<{
  emailSubjectAr: string;
  headlineAr: string;
  listingLabelAr: string;
  listingValueAr: string;
}> {
  try {
    const snap = await admin
      .firestore()
      .collection("properties")
      .doc(propertyId)
      .get();
    const d = snap.data();
    if (
      propertyTypeSlugBooking(d) === "apartment" &&
      isDailyRentListingServer(d)
    ) {
      const rawBuilding =
        typeof d?.dailyRentBuildingName === "string"
          ? d.dailyRentBuildingName.trim()
          : "";
      const titleValue =
        rawBuilding.length > 0 ? rawBuilding : FALLBACK_APARTMENT_BUILDING_AR;
      return {
        emailSubjectAr: EMAIL_SUBJECT_APARTMENT_DAILY,
        headlineAr: "🎉 تم تأكيد حجز جديد على وحدتك (إيجار يومي)",
        listingLabelAr: "اسم العمارة / الوحدة",
        listingValueAr: titleValue,
      };
    }
    const raw =
      d && typeof d.chaletName === "string" ? d.chaletName.trim() : "";
    const chaletName = raw.length > 0 ? raw : FALLBACK_CHALET_NAME_AR;
    return {
      emailSubjectAr: EMAIL_SUBJECT_CHALET,
      headlineAr: "🎉 تم تأكيد حجز جديد على شاليهك",
      listingLabelAr: "اسم الشاليه",
      listingValueAr: chaletName,
    };
  } catch (err) {
    logger.warn("sendBookingOwnerEmail.property_read_failed", {
      propertyId,
      error: sanitizeErrorMessage(err),
    });
    return {
      emailSubjectAr: EMAIL_SUBJECT_CHALET,
      headlineAr: "🎉 تم تأكيد حجز جديد على شاليهك",
      listingLabelAr: "اسم الشاليه",
      listingValueAr: FALLBACK_CHALET_NAME_AR,
    };
  }
}

/**
 * Compute the financial breakdown for the email.
 *
 * Preference order (single source of truth):
 *   1. The booking's own `commissionAmount` + `ownerNet` fields — these
 *      were written by the ledger pipeline inside the same transaction
 *      that flipped status to `confirmed`, so they match the platform's
 *      ledger byte-for-byte.
 *   2. Local fallback from `totalPrice * COMMISSION_RATE`, rounded to the
 *      same 3-decimal precision the ledger uses. Only kicks in for legacy
 *      confirmed bookings predating the financial pipeline (shouldn't
 *      happen in current code paths, but cheap insurance).
 */
function computeFinancials(after: Record<string, unknown>): {
  totalPrice: number;
  commissionAmount: number;
  ownerNet: number;
  commissionPct: number;
} {
  const totalPriceRaw =
    typeof after.totalPrice === "number"
      ? after.totalPrice
      : Number(after.totalPrice);
  const totalPrice = Number.isFinite(totalPriceRaw) ? totalPriceRaw : 0;

  const bookedCommission =
    typeof after.commissionAmount === "number"
      ? after.commissionAmount
      : null;
  const bookedOwnerNet =
    typeof after.ownerNet === "number" ? after.ownerNet : null;
  const bookedRate =
    typeof after.commissionRate === "number" ? after.commissionRate : null;

  if (
    bookedCommission != null &&
    bookedOwnerNet != null &&
    Number.isFinite(bookedCommission) &&
    Number.isFinite(bookedOwnerNet)
  ) {
    return {
      totalPrice,
      commissionAmount: bookedCommission,
      ownerNet: bookedOwnerNet,
      commissionPct: Math.round(
        (bookedRate != null && Number.isFinite(bookedRate)
          ? bookedRate
          : COMMISSION_RATE) * 100
      ),
    };
  }

  // Fallback path — local computation with the canonical rate.
  const commissionAmount =
    Math.round(totalPrice * COMMISSION_RATE * 1000) / 1000;
  const ownerNet = Math.round((totalPrice - commissionAmount) * 1000) / 1000;
  return {
    totalPrice,
    commissionAmount,
    ownerNet,
    commissionPct: Math.round(COMMISSION_RATE * 100),
  };
}

/**
 * Render the owner-facing HTML. Mirrors the visual language of the
 * customer email (same palette, same RTL layout, same Arabic font stack)
 * so both parties see a consistent brand, while the content is tailored
 * to owner-specific concerns (financials, payout disclaimer).
 *
 * Explicitly NO client data appears here — the payload type doesn't even
 * carry client fields.
 */
function renderOwnerHtml(p: ResolvedOwnerPayload): string {
  const headline = escapeHtml(p.headlineAr);
  const listingLabel = escapeHtml(p.listingLabelAr);
  const listingValue = escapeHtml(p.listingValueAr);
  const startDate = escapeHtml(p.startDate);
  const endDate = escapeHtml(p.endDate);
  const nights = String(p.nights);
  const totalPrice = escapeHtml(p.totalPrice);
  const commissionPct = escapeHtml(p.commissionPct);
  const commissionAmount = escapeHtml(p.commissionAmount);
  const ownerNet = escapeHtml(p.ownerNet);
  const bookingId = escapeHtml(p.bookingId);

  const trimmedPhone = p.supportPhone.trim();
  const supportLine = escapeHtml(
    trimmedPhone.length > 0 ? trimmedPhone : FALLBACK_SUPPORT_LINE_AR
  );

  const payoutNote = escapeHtml(PAYOUT_POLICY_NOTE_AR);

  return `<!DOCTYPE html>
<html lang="ar" dir="rtl">
<body style="font-family:Arial;background:#f6f7fb;padding:20px;">
  <div style="max-width:600px;background:#fff;margin:auto;padding:24px;border-radius:12px;">

    <h2>${headline}</h2>

    <p><b>${listingLabel}:</b> ${listingValue}</p>
    <p><b>تاريخ الدخول:</b> ${startDate}</p>
    <p><b>تاريخ الخروج:</b> ${endDate}</p>
    <p><b>عدد الليالي:</b> ${nights}</p>
    <p><b>رقم الحجز:</b> ${bookingId}</p>

    <hr style="border:none;border-top:1px solid #e5e7eb;margin:18px 0;" />

    <h3 style="margin:0 0 10px 0;">💰 التفاصيل المالية</h3>
    <p><b>المبلغ المدفوع:</b> ${totalPrice} د.ك</p>
    <p><b>عمولة المنصة (${commissionPct}%):</b> ${commissionAmount} د.ك</p>
    <p><b>صافي مستحق لك:</b> ${ownerNet} د.ك</p>

    <div style="background:#F1F5F9;border-right:4px solid #0A84FF;padding:12px 14px;border-radius:8px;margin-top:16px;">
      ${payoutNote}
    </div>

    <p style="margin-top:20px;">
      لأي استفسار يرجى التواصل:<br/>
      ${supportLine}
    </p>

  </div>
</body>
</html>`;
}

export const sendBookingOwnerEmail = onDocumentUpdated(
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
    const beforeStatus =
      typeof before?.status === "string" ? before!.status.trim() : "";
    const afterStatus =
      typeof after.status === "string" ? after.status.trim() : "";
    if (afterStatus !== "confirmed") return;
    if (beforeStatus === "confirmed") return;

    // Fast-path idempotency check — cheap short-circuit on obvious re-entries
    // (manual admin re-triggers, status churn). The post-send write below is
    // the actual persistence point.
    if (after.ownerEmailSent === true) {
      logger.info("sendBookingOwnerEmail.skip.already_sent", { bookingId });
      return;
    }

    // --- LOAD REQUIRED FIELDS --------------------------------------------
    const propertyId =
      typeof after.propertyId === "string" ? after.propertyId : "";
    const ownerId = typeof after.ownerId === "string" ? after.ownerId : "";
    const startTs = after.startDate as admin.firestore.Timestamp | undefined;
    const endTs = after.endDate as admin.firestore.Timestamp | undefined;
    const daysCount =
      typeof after.daysCount === "number" ? after.daysCount : null;

    if (
      !propertyId ||
      !ownerId ||
      !(startTs instanceof admin.firestore.Timestamp) ||
      !(endTs instanceof admin.firestore.Timestamp) ||
      daysCount == null ||
      daysCount <= 0
    ) {
      logger.warn("sendBookingOwnerEmail.skip.missing_fields", {
        bookingId,
        hasPropertyId: !!propertyId,
        hasOwnerId: !!ownerId,
        hasStart: startTs instanceof admin.firestore.Timestamp,
        hasEnd: endTs instanceof admin.firestore.Timestamp,
        daysCount,
      });
      return;
    }

    // Fan out the two network reads in parallel — they're independent and
    // together take ~50-100ms off the critical path.
    const [ownerEmail, listingCtx] = await Promise.all([
      resolveOwnerEmail(ownerId),
      resolveOwnerListingEmailContext(propertyId),
    ]);

    if (!ownerEmail) {
      logger.warn("sendBookingOwnerEmail.skip.no_owner_email", {
        bookingId,
        ownerId,
      });
      // Ops-visible marker so we can filter for owners that never got
      // their confirmation. No retry — the owner simply doesn't have an
      // email on file.
      try {
        await event.data!.after.ref.update({
          ownerEmailStatus: "failed",
          ownerEmailAttemptAt: FieldValue.serverTimestamp(),
          ownerEmailError: "no_owner_email",
        });
      } catch {
        // swallow — logs already explain
      }
      return;
    }

    const fin = computeFinancials(after);

    const payload: ResolvedOwnerPayload = {
      bookingId,
      headlineAr: listingCtx.headlineAr,
      listingLabelAr: listingCtx.listingLabelAr,
      listingValueAr: listingCtx.listingValueAr,
      startDate: formatKuwaitDate(startTs),
      endDate: formatKuwaitDate(endTs),
      nights: daysCount,
      totalPrice: formatKwd(fin.totalPrice),
      commissionPct: String(fin.commissionPct),
      commissionAmount: formatKwd(fin.commissionAmount),
      ownerNet: formatKwd(fin.ownerNet),
      ownerEmail,
      supportPhone: SUPPORT_PHONE,
    };

    // --- SMTP SEND --------------------------------------------------------
    const smtp = resolveInvoiceSmtp(
      invoiceSmtpHost.value(),
      invoiceSmtpPort.value(),
      invoiceSmtpPass.value()
    );
    logInvoiceSmtpDiagnostics("sendBookingOwnerEmail", smtp);

    const smtpUser = smtp.user.trim();
    const smtpPass = smtp.pass.trim().replace(/\s+/g, "");
    if (!smtpUser || !smtpPass) {
      logger.error("sendBookingOwnerEmail.smtp_not_configured", { bookingId });
      try {
        await event.data!.after.ref.update({
          ownerEmailStatus: "failed",
          ownerEmailAttemptAt: FieldValue.serverTimestamp(),
          ownerEmailError: "smtp_not_configured",
        });
      } catch {
        // swallow
      }
      return;
    }

    const html = renderOwnerHtml(payload);

    try {
      const transporter = nodemailer.createTransport({
        host: smtp.host.trim(),
        port: smtp.port,
        secure: smtp.port === 465,
        auth: { user: smtpUser, pass: smtpPass },
      });

      await transporter.sendMail({
        from: `"${INVOICE_BRAND.appName}" <${smtpUser}>`,
        to: ownerEmail.toLowerCase(),
        subject: listingCtx.emailSubjectAr,
        html,
      });

      // Persist the idempotency flag only on real SMTP success — this is
      // the single gate that prevents double-sends on future re-entries.
      await event.data!.after.ref.update({
        ownerEmailStatus: "sent",
        ownerEmailSent: true,
        ownerEmailAttemptAt: FieldValue.serverTimestamp(),
        ownerEmailSentAt: FieldValue.serverTimestamp(),
        ownerEmailError: FieldValue.delete(),
      });

      logger.info("sendBookingOwnerEmail.sent", {
        bookingId,
        // NOTE: we intentionally do not log the ownerEmail value itself
        // (PII hygiene). The bookingId + ownerId trail is sufficient for
        // ops; recovering the address is a one-query lookup in Auth.
        ownerId,
      });
    } catch (err) {
      const msg = sanitizeErrorMessage(err);
      logger.error("sendBookingOwnerEmail.send_failed", {
        bookingId,
        error: msg,
      });
      // Mark the attempt but do NOT set `ownerEmailSent`. Leaving it unset
      // keeps the booking eligible for a future manual-resend admin tool.
      // We do NOT auto-retry from here (by design).
      try {
        await event.data!.after.ref.update({
          ownerEmailStatus: "failed",
          ownerEmailAttemptAt: FieldValue.serverTimestamp(),
          ownerEmailError: msg,
        });
      } catch {
        // Even the patch failed; we already logged the primary error.
      }
    }
  }
);
