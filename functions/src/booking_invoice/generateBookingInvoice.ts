/**
 * Booking invoice generator (async).
 * Trigger: bookings/{bookingId} onUpdate when paymentStatus transitions to "paid".
 *
 * Writes:
 * - Storage: /invoices/{bookingId}.pdf
 * - Firestore: invoices/{invoiceId}
 * - Email (SMTP): client (to) + admin (bcc) + optional owner (cc)
 *
 * Errors are logged and persisted to invoice doc; never block payment flow.
 */
import * as admin from "firebase-admin";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { defineSecret, defineString } from "firebase-functions/params";
import { FieldValue } from "firebase-admin/firestore";

import { allocateInvoiceInTransaction } from "../invoice/allocateInvoice";
import {
  logInvoiceSmtpDiagnostics,
  resolveInvoiceSmtp,
} from "../invoice/invoiceSmtpRuntime";
import { INVOICE_BRAND } from "../invoice/constants";
import { renderBookingInvoicePdfBuffer } from "./renderBookingInvoicePdf";
import { uploadBookingInvoicePdfAndGetUrl } from "./uploadBookingInvoicePdf";
import { sendBookingInvoiceEmail } from "./sendBookingInvoiceEmail";
import { writeExceptionLog } from "../exceptionLogs";

const invoiceSmtpPass = defineSecret("INVOICE_SMTP_PASS");
const invoiceSmtpHost = defineString("INVOICE_SMTP_HOST", {
  default: "smtp.gmail.com",
});
const invoiceSmtpPort = defineString("INVOICE_SMTP_PORT", { default: "465" });

function str(v: unknown): string {
  if (v == null) return "";
  return String(v).trim();
}

function num(v: unknown, fallback = 0): number {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string") {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return fallback;
}

function paymentStatusPaid(v: unknown): boolean {
  return str(v).toLowerCase() === "paid";
}

async function resolveUserIdentity(uid: string): Promise<{
  name: string;
  email: string;
}> {
  const snap = await admin.firestore().collection("users").doc(uid).get();
  const d = snap.data() as Record<string, unknown> | undefined;
  const name = str(d?.name ?? d?.fullName ?? d?.displayName ?? d?.userName);
  const email = str(d?.email);
  return { name, email };
}

function propertyTitleFromPropertyDoc(p: Record<string, unknown> | undefined): string {
  const type = str(p?.type).toLowerCase();
  const svc = str(p?.serviceType).toLowerCase();
  const rt = str(p?.rentalType).toLowerCase();
  const pt = str(p?.priceType).toLowerCase();
  const apartmentDaily =
    type === "apartment" &&
    svc === "rent" &&
    (rt === "daily" || pt === "daily");
  if (apartmentDaily) {
    const bn = str(p?.dailyRentBuildingName);
    const area = str(p?.areaAr ?? p?.area);
    const parts = [(bn || "Daily apartment").slice(0, 120), area].filter((x) => x.length > 0);
    if (parts.length > 0) return parts.join(" · ").slice(0, 200);
  }
  const area = str(p?.areaAr ?? p?.area);
  const parts = [area, type].filter((x) => x.length > 0);
  if (parts.length > 0) return parts.join(" · ").slice(0, 200);
  const desc = str(p?.description);
  return desc.slice(0, 120) || "Chalet booking";
}

export const generateBookingInvoice = onDocumentUpdated(
  {
    document: "bookings/{bookingId}",
    region: "us-central1",
    secrets: [invoiceSmtpPass],
    timeoutSeconds: 180,
    memory: "1GiB",
  },
  async (event) => {
    const bookingId = event.params.bookingId;
    if (!bookingId) return;

    const before = event.data?.before?.data() as Record<string, unknown> | undefined;
    const after = event.data?.after?.data() as Record<string, unknown> | undefined;
    if (!after) return;

    // Trigger ONLY when paymentStatus changes to "paid".
    const beforePaid = before ? paymentStatusPaid(before.paymentStatus) : false;
    const afterPaid = paymentStatusPaid(after.paymentStatus);
    if (!afterPaid || beforePaid) return;

    const db = admin.firestore();

    const propertyId = str(after.propertyId);
    const ownerId = str(after.ownerId);
    const clientId = str(after.clientId);
    const paymentId = str(after.paymentId);

    const startTs = after.startDate as admin.firestore.Timestamp | undefined;
    const endTs = after.endDate as admin.firestore.Timestamp | undefined;
    const startDate = startTs?.toDate();
    const endDate = endTs?.toDate();

    const nights = Math.max(0, Math.round(num(after.daysCount, 0)));
    const pricePerNight = num(after.pricePerNight, 0);
    const totalAmount = num(after.totalPrice, 0);
    const commissionAmount = num(after.commissionAmount, 0);
    const ownerNet = num(after.ownerNet, 0);

    if (!propertyId || !ownerId || !clientId || !paymentId || !startDate || !endDate) {
      console.warn(
        JSON.stringify({
          tag: "booking_invoice_skip_invalid_booking",
          bookingId,
          propertyId,
          ownerId,
          clientId,
          paymentId,
        })
      );
      return;
    }

    // Resolve property title + client/owner info (best-effort).
    let propertyTitle = "Chalet booking";
    let clientName = "";
    let clientEmail = "";
    let ownerEmail = "";
    try {
      const [propSnap, client, owner] = await Promise.all([
        db.collection("properties").doc(propertyId).get(),
        resolveUserIdentity(clientId),
        resolveUserIdentity(ownerId),
      ]);
      propertyTitle = propertyTitleFromPropertyDoc(
        (propSnap.data() as Record<string, unknown> | undefined) ?? undefined
      );
      clientName = client.name;
      clientEmail = client.email;
      ownerEmail = owner.email;
    } catch (e) {
      console.error(
        JSON.stringify({
          tag: "booking_invoice_context_resolve_failed",
          bookingId,
          error: e instanceof Error ? e.message : String(e),
        })
      );
    }

    // 1) Allocate invoice doc (idempotent per paymentId).
    const allocated = await allocateInvoiceInTransaction(db, paymentId, () => ({
      invoiceId: "",
      bookingId,
      paymentId,
      propertyId,
      ownerId,
      // Auth UID of the guest who paid — used by Firestore rules so the user
      // can read their own invoice (Financial Hardening Phase 1).
      clientId,
      totalAmount,
      commissionAmount,
      ownerNet,
      fileUrl: "",
      status: "issued",
      kind: "booking",
    }));
    if (!allocated) {
      // Invoice already exists for this paymentId; do not duplicate work.
      return;
    }

    const { invoiceRef, invoiceNumber } = allocated;

    // 2) Generate PDF + upload to Storage.
    let pdfBuffer: Buffer | null = null;
    let pdfUrl = "";
    let pdfStoragePath = "";
    try {
      pdfBuffer = await renderBookingInvoicePdfBuffer({
        invoiceNumber,
        invoiceDate: new Date(),
        bookingId,
        paymentId,
        propertyTitle,
        billToName: clientName || "Valued Customer",
        billToEmail: clientEmail,
        startDate,
        endDate,
        nights,
        pricePerNight,
        totalAmount,
        commissionAmount,
        ownerNet,
      });

      const uploaded = await uploadBookingInvoicePdfAndGetUrl({
        buffer: pdfBuffer,
        bookingId,
      });
      pdfUrl = uploaded.pdfUrl;
      pdfStoragePath = uploaded.pdfStoragePath;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(
        JSON.stringify({
          tag: "booking_invoice_pdf_failed",
          bookingId,
          invoiceId: invoiceRef.id,
          error: msg,
        })
      );
      void writeExceptionLog({
        type: "invoice_pdf_failed",
        relatedId: bookingId,
        message: `invoice ${invoiceRef.id}: ${msg || "pdf_failed"}`,
        severity: "high",
      });
      await invoiceRef.update({
        status: "issued",
        pdfError: msg || "pdf_failed",
        pdfErrorAt: FieldValue.serverTimestamp(),
      });
      return;
    }

    // 3) Persist invoice metadata + storage URL.
    await invoiceRef.set(
      {
        invoiceId: invoiceRef.id,
        bookingId,
        paymentId,
        propertyId,
        ownerId,
        clientId,
        totalAmount,
        commissionAmount,
        ownerNet,
        fileUrl: pdfUrl,
        pdfUrl,
        pdfStoragePath,
        status: "paid",
        currency: "KWD",
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    // Optional: mirror URL on booking for later app display.
    try {
      await db.collection("bookings").doc(bookingId).update({
        invoiceId: invoiceRef.id,
        invoiceUrl: pdfUrl,
        invoiceReadyAt: FieldValue.serverTimestamp(),
      });
    } catch (e) {
      console.warn(
        JSON.stringify({
          tag: "booking_invoice_booking_patch_failed",
          bookingId,
          error: e instanceof Error ? e.message : String(e),
        })
      );
    }

    // 4) Send email (best-effort).
    try {
      const smtpResolved = resolveInvoiceSmtp(
        invoiceSmtpHost.value(),
        invoiceSmtpPort.value(),
        invoiceSmtpPass.value()
      );
      logInvoiceSmtpDiagnostics("generateBookingInvoice", smtpResolved);

      const emailResult = await sendBookingInvoiceEmail({
        smtp: smtpResolved,
        to: clientEmail && clientEmail.includes("@") ? clientEmail : null,
        bccAdmin: true,
        ccOwnerEmail: ownerEmail && ownerEmail.includes("@") ? ownerEmail : null,
        subject: "Invoice - Booking Confirmation",
        bodyText:
          "Your booking payment has been received. Please find your invoice attached.",
        pdfBuffer: pdfBuffer!,
        pdfFileName: `${invoiceNumber}.pdf`,
      });

      const emailPatch: Record<string, unknown> = {
        emailAttemptAt: FieldValue.serverTimestamp(),
        emailSent: emailResult.sent,
      };
      if (emailResult.sent) {
        emailPatch.emailSentAt = FieldValue.serverTimestamp();
        emailPatch.emailError = FieldValue.delete();
      } else if (emailResult.attempted && emailResult.error) {
        emailPatch.emailError = emailResult.error;
      } else if (!emailResult.attempted) {
        emailPatch.emailError = FieldValue.delete();
      }

      await invoiceRef.update(emailPatch);

      if (!emailResult.attempted) {
        console.warn(
          JSON.stringify({
            tag: "booking_invoice_smtp_not_configured",
            bookingId,
            invoiceId: invoiceRef.id,
            adminCopyEmail: INVOICE_BRAND.adminCopyEmail,
          })
        );
        void writeExceptionLog({
          type: "email_failed",
          relatedId: bookingId,
          message: `invoice ${invoiceRef.id}: SMTP not configured`,
          severity: "low",
        });
      } else if (!emailResult.sent && emailResult.attempted && emailResult.error) {
        void writeExceptionLog({
          type: "email_failed",
          relatedId: bookingId,
          message: `invoice ${invoiceRef.id}: ${emailResult.error}`,
          severity: "medium",
        });
      }
    } catch (e) {
      console.error(
        JSON.stringify({
          tag: "booking_invoice_email_failed",
          bookingId,
          invoiceId: invoiceRef.id,
          error: e instanceof Error ? e.message : String(e),
        })
      );
      void writeExceptionLog({
        type: "email_failed",
        relatedId: bookingId,
        message: `invoice ${invoiceRef.id}: ${e instanceof Error ? e.message : String(e)}`,
        severity: "high",
      });
      await invoiceRef.update({
        emailAttemptAt: FieldValue.serverTimestamp(),
        emailSent: false,
        emailError: e instanceof Error ? e.message : String(e),
      });
    }
  }
);

