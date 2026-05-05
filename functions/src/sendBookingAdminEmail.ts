/**
 * Firestore trigger: send an ADMIN-ONLY monitoring email containing the
 * full operational breakdown when a booking flips to `status: "confirmed"`.
 *
 * RELATIONSHIP TO THE OTHER TWO EMAIL TRIGGERS
 *   - `sendBookingCustomerEmail`  →  customer inbox, no financials
 *   - `sendBookingOwnerEmail`     →  owner inbox, financial summary, no client PII
 *   - `sendBookingAdminEmail`     →  aqaraiapp@gmail.com, FULL data (this file)
 *
 *   All three fire on the same `pending_payment -> confirmed` transition
 *   and run in PARALLEL. None blocks the others. Each writes into a
 *   disjoint `{customer|owner|admin}*` status namespace on the booking
 *   doc so one failing never corrupts the others.
 *
 *   Because the three run concurrently, by the time the admin email is
 *   being composed the peer `customerEmailStatus` / `ownerEmailStatus`
 *   fields may or may not be populated yet. We therefore re-read the
 *   booking doc right before sending — catches the peers when they've
 *   already committed, shows "Pending" otherwise. The warning block only
 *   fires on the literal string `"failed"`, never on absent/unknown
 *   values, so we never false-alarm ops.
 *
 * NON-NEGOTIABLES
 *   - Fires ONLY on the confirmed transition. Never on any other status.
 *   - Never crashes. All errors caught; runtime told not to retry.
 *   - Never modifies booking business data. Writes confined to the
 *     `admin*` namespace.
 *   - Destination is exactly ONE admin address. No CC, no BCC, no
 *     per-booking recipient lists. If admin routing ever changes, update
 *     a single constant.
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
 * Hardcoded admin destination. Intentionally aliased to the existing
 * [INVOICE_BRAND.adminCopyEmail] so if the org-wide admin mailbox moves,
 * it's one edit. DO NOT add additional recipients here — the spec
 * explicitly requires a single destination for the monitoring stream.
 */
const ADMIN_EMAIL = INVOICE_BRAND.adminCopyEmail;

interface AdminEmailPayload {
  // identifiers
  bookingId: string;
  propertyId: string;
  ownerId: string;
  clientId: string;
  // client
  clientEmail: string;
  clientPhone: string;
  // owner
  ownerPhone: string;
  // booking
  listingKindRowLabel: string;
  listingDisplayName: string;
  arrivalContactPhone: string;
  startDate: string;
  endDate: string;
  nights: number;
  // financials (strings, already formatted for display)
  totalPrice: string;
  commissionPct: string;
  commissionAmount: string;
  ownerNet: string;
  // location
  googleMapsLink: string;
  // timestamps (formatted)
  createdAt: string;
  confirmedAt: string;
  // statuses
  bookingStatus: string;
  customerEmailStatus: string;
  ownerEmailStatus: string;
  // derived alert flag
  hasEmailFailures: boolean;
}

/** Cap + single-line an error message before persisting to Firestore. */
function sanitizeErrorMessage(raw: unknown): string {
  const s = raw instanceof Error ? raw.message : String(raw ?? "");
  return s.replace(/\s+/g, " ").trim().slice(0, 300);
}

/** Asia/Kuwait `dd/MM/yyyy HH:mm` for operational logs. More precision
 *  than the customer/owner emails because ops cares about exact timing. */
function formatKuwaitDateTime(ts: admin.firestore.Timestamp): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Kuwait",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(ts.toDate());
}

/** Same date-only format used in the customer/owner emails so a human
 *  can cross-reference rows between inboxes without conversion. */
function formatKuwaitDate(ts: admin.firestore.Timestamp): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Kuwait",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(ts.toDate());
}

/** KWD canonical 3-decimal display. */
function formatKwd(raw: unknown): string {
  const n = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(n)) return "0.000";
  return (Math.round(n * 1000) / 1000).toFixed(3);
}

function escapeHtml(input: string): string {
  return input
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** "—" for anything we don't have yet, so the admin can visually scan
 *  what's missing without being misled by empty cells. */
function orDash(s: string | null | undefined): string {
  const v = (s ?? "").trim();
  return v.length > 0 ? v : "—";
}

/**
 * Normalize the peer-email status into a display-safe string. We never
 * propagate unknown / absent values as "failed" — only the explicit
 * literal `"failed"` triggers the warning block.
 */
function normalizeEmailStatus(raw: unknown): string {
  if (typeof raw !== "string") return "pending";
  const s = raw.trim().toLowerCase();
  if (s === "sent" || s === "failed") return s;
  return "pending";
}

/** Best-effort phone extraction from a user doc (schema varies slightly
 *  across older + newer documents). Ordered by project convention. */
function phoneFromUserDoc(d: Record<string, unknown> | null | undefined): string {
  if (!d) return "";
  const candidates = [d.phone, d.phoneNumber, d.ownerPhone];
  for (const v of candidates) {
    if (typeof v === "string" && v.trim().length > 0) {
      return v.trim();
    }
  }
  return "";
}

/**
 * Compute commission + ownerNet. Prefer values the ledger pipeline
 * already wrote onto the booking doc (ground truth); fall back to a
 * local `totalPrice * 0.15` only for legacy confirmed bookings that
 * predate the financial pipeline.
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
    typeof after.commissionAmount === "number" ? after.commissionAmount : null;
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
 * Render a simple, scan-friendly HTML report for ops. Intentionally
 * unstyled beyond minimum readability — the purpose is machine-readable
 * by eye, not brand polish. LTR throughout (identifiers, English
 * section titles) with Arabic chalet name passed through intact.
 */
function renderAdminHtml(p: AdminEmailPayload): string {
  const row = (label: string, value: string) =>
    `<tr>
      <td style="padding:4px 10px 4px 0;color:#555;white-space:nowrap;"><b>${escapeHtml(label)}</b></td>
      <td style="padding:4px 0;">${escapeHtml(value)}</td>
    </tr>`;

  const section = (title: string, rows: string) =>
    `<h3 style="margin:22px 0 6px 0;color:#0D2B4D;border-bottom:1px solid #e5e7eb;padding-bottom:4px;">${escapeHtml(title)}</h3>
     <table style="border-collapse:collapse;font-size:13px;">${rows}</table>`;

  const warningBlock = p.hasEmailFailures
    ? `<div style="background:#FEF3C7;border-left:4px solid #F59E0B;padding:12px 14px;border-radius:6px;margin:12px 0 6px 0;">
         <b>⚠️ Warning:</b> Some emails failed to send. Check the per-field status below.
       </div>`
    : "";

  const mapsRow = p.googleMapsLink
    ? `<tr>
         <td style="padding:4px 10px 4px 0;color:#555;"><b>Google Maps</b></td>
         <td style="padding:4px 0;"><a href="${escapeHtml(p.googleMapsLink)}" style="color:#0A84FF;">${escapeHtml(p.googleMapsLink)}</a></td>
       </tr>`
    : row("Google Maps", "—");

  return `<!DOCTYPE html>
<html lang="en" dir="ltr">
<body style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Arial,sans-serif;background:#f6f7fb;padding:20px;color:#111;">
  <div style="max-width:720px;background:#fff;margin:auto;padding:22px 26px;border-radius:10px;border:1px solid #e5e7eb;">

    <h2 style="margin:0 0 4px 0;">Booking Confirmed — ${escapeHtml(p.bookingId)}</h2>
    <div style="color:#6b7280;font-size:12px;margin-bottom:8px;">Internal ops report · AqarAi admin monitoring</div>

    ${warningBlock}

    ${section("1. Identifiers", [
      row("Booking ID", p.bookingId),
      row("Property ID", p.propertyId),
      row("Owner ID", p.ownerId),
      row("Client ID", p.clientId),
    ].join(""))}

    ${section("2. Client", [
      row("Email", p.clientEmail),
      row("Phone", p.clientPhone),
    ].join(""))}

    ${section("3. Owner", [
      row("Phone", p.ownerPhone),
    ].join(""))}

    ${section("4. Booking", [
      row(p.listingKindRowLabel, p.listingDisplayName),
      row("Start Date", p.startDate),
      row("End Date", p.endDate),
      row("Nights", String(p.nights)),
      row("Arrival contact (guest-facing)", p.arrivalContactPhone),
    ].join(""))}

    ${section("5. Financials", [
      row("Total Price", `${p.totalPrice} KWD`),
      row(`Commission (${p.commissionPct}%)`, `${p.commissionAmount} KWD`),
      row("Owner Net", `${p.ownerNet} KWD`),
    ].join(""))}

    ${section("6. Location", mapsRow)}

    ${section("7. Timestamps (Asia/Kuwait)", [
      row("Created At", p.createdAt),
      row("Confirmed At", p.confirmedAt),
    ].join(""))}

    ${section("8. Status", [
      row("Booking", p.bookingStatus),
      row("Customer Email", p.customerEmailStatus),
      row("Owner Email", p.ownerEmailStatus),
    ].join(""))}

    <p style="margin-top:24px;color:#6b7280;font-size:11px;">
      This is an automated monitoring message. Do not reply.
    </p>
  </div>
</body>
</html>`;
}

export const sendBookingAdminEmail = onDocumentUpdated(
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
    const afterEvent = event.data?.after?.data();
    if (!afterEvent) return;

    // --- TRIGGER GUARDS --------------------------------------------------
    const beforeStatus =
      typeof before?.status === "string" ? before!.status.trim() : "";
    const afterStatus =
      typeof afterEvent.status === "string" ? afterEvent.status.trim() : "";
    if (afterStatus !== "confirmed") return;
    if (beforeStatus === "confirmed") return;

    if (afterEvent.adminEmailSent === true) {
      logger.info("sendBookingAdminEmail.skip.already_sent", { bookingId });
      return;
    }

    // Re-read the booking so the peer email statuses (customerEmailStatus /
    // ownerEmailStatus) have the best chance of being populated by the
    // sibling triggers that started at roughly the same instant. If we're
    // still first, they'll read as "pending" which the warning block
    // correctly ignores. This costs ~1 extra read per confirmation.
    let fresh: Record<string, unknown> = afterEvent;
    try {
      const snap = await event.data!.after.ref.get();
      if (snap.exists) fresh = snap.data()!;
    } catch {
      // keep the event payload; non-fatal
    }
    // Guard against a race where another path already sent between our
    // fast-path check and the re-read.
    if (fresh.adminEmailSent === true) {
      logger.info("sendBookingAdminEmail.skip.already_sent", { bookingId });
      return;
    }

    // --- REQUIRED FIELDS -------------------------------------------------
    const propertyId = typeof fresh.propertyId === "string" ? fresh.propertyId : "";
    const ownerId = typeof fresh.ownerId === "string" ? fresh.ownerId : "";
    const clientId = typeof fresh.clientId === "string" ? fresh.clientId : "";
    const startTs = fresh.startDate as admin.firestore.Timestamp | undefined;
    const endTs = fresh.endDate as admin.firestore.Timestamp | undefined;
    const daysCount =
      typeof fresh.daysCount === "number" ? fresh.daysCount : null;

    if (
      !propertyId ||
      !ownerId ||
      !clientId ||
      !(startTs instanceof admin.firestore.Timestamp) ||
      !(endTs instanceof admin.firestore.Timestamp) ||
      daysCount == null ||
      daysCount <= 0
    ) {
      logger.warn("sendBookingAdminEmail.skip.missing_fields", {
        bookingId,
        hasPropertyId: !!propertyId,
        hasOwnerId: !!ownerId,
        hasClientId: !!clientId,
        hasStart: startTs instanceof admin.firestore.Timestamp,
        hasEnd: endTs instanceof admin.firestore.Timestamp,
        daysCount,
      });
      return;
    }

    const db = admin.firestore();

    // --- PARALLEL LOOKUPS ------------------------------------------------
    // Three independent I/O calls: property doc, client user doc, client
    // auth record. Running in parallel saves ~150-300ms off the critical
    // path. Each handler is defensive — any one failing just falls back to
    // empty strings; the email still sends with "—" in the missing cells.
    const [propSnap, clientUserSnap, clientAuth] = await Promise.all([
      db.collection("properties").doc(propertyId).get().catch(() => null),
      db.collection("users").doc(clientId).get().catch(() => null),
      admin.auth().getUser(clientId).catch(() => null),
    ]);

    const propData = propSnap?.exists ? propSnap.data() ?? {} : {};
    const clientUserData = clientUserSnap?.exists
      ? clientUserSnap.data() ?? {}
      : {};

    const pd = propData as admin.firestore.DocumentData;
    const apartmentDaily =
      propertyTypeSlugBooking(pd) === "apartment" &&
      isDailyRentListingServer(pd);

    let listingKindRowLabel = "Chalet Name";
    let listingDisplayName = "—";
    let arrivalContactPhone = "—";
    let googleMapsLink = "";

    if (apartmentDaily) {
      listingKindRowLabel = "Building / unit (daily apartment)";
      const b =
        typeof propData.dailyRentBuildingName === "string"
          ? propData.dailyRentBuildingName.trim()
          : "";
      listingDisplayName = b.length > 0 ? b : "—";
      const ac =
        typeof propData.dailyRentContactPhone === "string"
          ? propData.dailyRentContactPhone.trim()
          : "";
      arrivalContactPhone = ac.length > 0 ? ac : "—";
      const dm =
        typeof propData.dailyRentMapsLink === "string"
          ? propData.dailyRentMapsLink.trim()
          : "";
      googleMapsLink = dm.startsWith("http") ? dm : "";
    } else {
      listingDisplayName =
        typeof propData.chaletName === "string" && propData.chaletName.trim().length > 0
          ? propData.chaletName.trim()
          : "—";
      googleMapsLink =
        typeof propData.googleMapsLink === "string"
          ? propData.googleMapsLink.trim()
          : "";
    }

    const ownerPhone =
      (typeof propData.ownerPhone === "string" && propData.ownerPhone.trim()) ||
      "";

    // Client email: auth is authoritative, users doc is fallback.
    const clientEmailFromAuth =
      clientAuth?.email && clientAuth.email.includes("@")
        ? clientAuth.email.trim()
        : "";
    const clientEmailFromDoc =
      typeof clientUserData.email === "string" && clientUserData.email.includes("@")
        ? clientUserData.email.trim()
        : "";
    const clientEmail = clientEmailFromAuth || clientEmailFromDoc || "";

    // Client phone: Auth.phoneNumber wins; users doc as backup.
    const clientPhoneFromAuth =
      typeof clientAuth?.phoneNumber === "string" && clientAuth.phoneNumber.trim().length > 0
        ? clientAuth.phoneNumber.trim()
        : "";
    const clientPhone = clientPhoneFromAuth || phoneFromUserDoc(clientUserData);

    const fin = computeFinancials(fresh);

    const customerEmailStatus = normalizeEmailStatus(fresh.customerEmailStatus);
    const ownerEmailStatus = normalizeEmailStatus(fresh.ownerEmailStatus);
    const hasEmailFailures =
      customerEmailStatus === "failed" || ownerEmailStatus === "failed";

    const createdAtTs =
      fresh.createdAt instanceof admin.firestore.Timestamp
        ? fresh.createdAt
        : null;
    const confirmedAtTs =
      fresh.confirmedAt instanceof admin.firestore.Timestamp
        ? fresh.confirmedAt
        : null;

    const payload: AdminEmailPayload = {
      bookingId,
      propertyId,
      ownerId,
      clientId,
      clientEmail: orDash(clientEmail),
      clientPhone: orDash(clientPhone),
      ownerPhone: orDash(ownerPhone),
      listingKindRowLabel,
      listingDisplayName: orDash(listingDisplayName),
      arrivalContactPhone: orDash(arrivalContactPhone),
      startDate: formatKuwaitDate(startTs),
      endDate: formatKuwaitDate(endTs),
      nights: daysCount,
      totalPrice: formatKwd(fin.totalPrice),
      commissionPct: String(fin.commissionPct),
      commissionAmount: formatKwd(fin.commissionAmount),
      ownerNet: formatKwd(fin.ownerNet),
      googleMapsLink,
      createdAt: createdAtTs ? formatKuwaitDateTime(createdAtTs) : "—",
      confirmedAt: confirmedAtTs ? formatKuwaitDateTime(confirmedAtTs) : "—",
      bookingStatus: afterStatus,
      customerEmailStatus,
      ownerEmailStatus,
      hasEmailFailures,
    };

    // --- SMTP SEND --------------------------------------------------------
    const smtp = resolveInvoiceSmtp(
      invoiceSmtpHost.value(),
      invoiceSmtpPort.value(),
      invoiceSmtpPass.value()
    );
    logInvoiceSmtpDiagnostics("sendBookingAdminEmail", smtp);

    const smtpUser = smtp.user.trim();
    const smtpPass = smtp.pass.trim().replace(/\s+/g, "");
    if (!smtpUser || !smtpPass) {
      logger.error("sendBookingAdminEmail.smtp_not_configured", { bookingId });
      try {
        await event.data!.after.ref.update({
          adminEmailStatus: "failed",
          adminEmailAttemptAt: FieldValue.serverTimestamp(),
          adminEmailError: "smtp_not_configured",
        });
      } catch {
        // swallow
      }
      return;
    }

    const html = renderAdminHtml(payload);

    try {
      const transporter = nodemailer.createTransport({
        host: smtp.host.trim(),
        port: smtp.port,
        secure: smtp.port === 465,
        auth: { user: smtpUser, pass: smtpPass },
      });

      await transporter.sendMail({
        from: `"${INVOICE_BRAND.appName} Ops" <${smtpUser}>`,
        to: ADMIN_EMAIL,
        subject: `Booking Confirmed — ${bookingId}`,
        html,
      });

      await event.data!.after.ref.update({
        adminEmailStatus: "sent",
        adminEmailSent: true,
        adminEmailAttemptAt: FieldValue.serverTimestamp(),
        adminEmailSentAt: FieldValue.serverTimestamp(),
        adminEmailError: FieldValue.delete(),
      });

      logger.info("sendBookingAdminEmail.sent", {
        bookingId,
        hasEmailFailures,
      });
    } catch (err) {
      const msg = sanitizeErrorMessage(err);
      logger.error("sendBookingAdminEmail.send_failed", {
        bookingId,
        error: msg,
      });
      try {
        await event.data!.after.ref.update({
          adminEmailStatus: "failed",
          adminEmailAttemptAt: FieldValue.serverTimestamp(),
          adminEmailError: msg,
        });
      } catch {
        // Even the patch failed; primary error already in logs.
      }
    }
  }
);
