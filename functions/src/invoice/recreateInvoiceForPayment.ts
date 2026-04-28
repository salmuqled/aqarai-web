/**
 * Admin recovery: cancel current invoice row(s) for a payment, allocate a new invoice,
 * finalize paid without duplicating financial_ledger when a ledger row already exists for paymentId,
 * then PDF + email pipeline.
 */
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret, defineString } from "firebase-functions/params";

import { isAdminFromCallableAuth } from "./adminAuth";
import { cancelActiveInvoicesAndAllocateNewForPayment } from "./allocateInvoice";
import {
  commitFinalizePaidRespectingExistingLedgerByPayment,
} from "./finalizePaidAndLedger";
import {
  applyPdfSuccessToInvoice,
  generateUploadInvoicePdf,
} from "./invoicePdfPipeline";
import { resolvePaymentInvoiceContext } from "./resolvePaymentInvoiceContext";
import {
  type InvoiceSmtpResolved,
  logInvoiceSmtpDiagnostics,
  resolveInvoiceSmtp,
  smtpDiagnosticsPayload,
} from "./invoiceSmtpRuntime";
import { sendInvoiceEmails } from "./sendInvoiceEmail";

const invoiceSmtpPass = defineSecret("INVOICE_SMTP_PASS");
const invoiceSmtpHost = defineString("INVOICE_SMTP_HOST", {
  default: "smtp.gmail.com",
});
const invoiceSmtpPort = defineString("INVOICE_SMTP_PORT", { default: "465" });

function str(v: unknown): string {
  if (v == null) return "";
  return String(v);
}

function yearFromInvoiceNumber(invoiceNumber: string): number {
  const m = /^INV-KWT-(\d{4})-/i.exec(invoiceNumber.trim());
  if (m) return parseInt(m[1], 10);
  return parseInt(
    new Intl.DateTimeFormat("en-US", {
      timeZone: "Asia/Kuwait",
      year: "numeric",
    }).format(new Date()),
    10
  );
}

function assertAdmin(request: { auth?: { token?: Record<string, unknown> } }) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }
  if (!isAdminFromCallableAuth(request.auth)) {
    throw new HttpsError("permission-denied", "Admin only");
  }
}

export const recreateInvoiceForPayment = onCall(
  {
    region: "us-central1",
    secrets: [invoiceSmtpPass],
    timeoutSeconds: 180,
    memory: "1GiB",
  },
  async (request) => {
    assertAdmin(request);

    const paymentId = str(
      (request.data as { paymentId?: string })?.paymentId
    ).trim();
    if (!paymentId) {
      throw new HttpsError("invalid-argument", "paymentId is required");
    }

    const db = admin.firestore();
    const paySnap = await db.collection("company_payments").doc(paymentId).get();
    if (!paySnap.exists) {
      throw new HttpsError("not-found", "Payment not found");
    }
    const payment = paySnap.data() as Record<string, unknown>;

    const invCheck = await db
      .collection("invoices")
      .where("paymentId", "==", paymentId)
      .limit(1)
      .get();
    if (invCheck.empty) {
      throw new HttpsError("not-found", "No invoice for this payment");
    }

    const ctx = await resolvePaymentInvoiceContext(paymentId, payment);
    if (!ctx) {
      throw new HttpsError(
        "failed-precondition",
        "Could not resolve invoice context from payment"
      );
    }

    const allocated = await cancelActiveInvoicesAndAllocateNewForPayment(
      db,
      paymentId,
      () => ({
        companyId: ctx.companyId,
        companyName: ctx.companyName,
        clientId: ctx.clientId,
        amount: ctx.amount,
        serviceType: ctx.serviceType,
        area: ctx.area,
        description: ctx.descriptionAr,
        status: "issued",
        emailSent: false,
      })
    );

    if (!allocated) {
      throw new HttpsError(
        "failed-precondition",
        "Could not allocate replacement invoice"
      );
    }

    const { invoiceRef, invoiceNumber, year } = allocated;

    await commitFinalizePaidRespectingExistingLedgerByPayment(
      db,
      invoiceRef,
      paymentId
    );

    let smtpResolvedForResponse: InvoiceSmtpResolved | null = null;

    try {
      const { pdfBuffer, pdfUrl, pdfStoragePath } =
        await generateUploadInvoicePdf({
          invoiceNumber,
          year,
          ctx,
          invoiceStatusForPdf: "paid",
          paymentId,
        });

      await applyPdfSuccessToInvoice(invoiceRef, pdfUrl, pdfStoragePath);

      smtpResolvedForResponse = resolveInvoiceSmtp(
        invoiceSmtpHost.value(),
        invoiceSmtpPort.value(),
        invoiceSmtpPass.value()
      );
      logInvoiceSmtpDiagnostics(
        "recreateInvoiceForPayment",
        smtpResolvedForResponse
      );

      const emailResult = await sendInvoiceEmails({
        smtp: smtpResolvedForResponse,
        companyEmail: ctx.companyEmail,
        pdfBuffer,
        pdfFileName: `${invoiceNumber}.pdf`,
      });

      const emailPatch: Record<string, unknown> = {
        emailSent: emailResult.sent,
        emailAttemptAt: FieldValue.serverTimestamp(),
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
          "recreateInvoiceForPayment: SMTP not configured; PDF stored only.",
          paymentId
        );
      }
    } catch (err) {
      console.error(
        "recreateInvoiceForPayment: PDF/email failed",
        paymentId,
        err
      );
      await invoiceRef.update({
        pdfError: str((err as Error)?.message) || "pdf_or_email_failed",
        pdfErrorAt: FieldValue.serverTimestamp(),
      });
    }

    const smtpForDiagnostics =
      smtpResolvedForResponse ??
      resolveInvoiceSmtp(
        invoiceSmtpHost.value(),
        invoiceSmtpPort.value(),
        invoiceSmtpPass.value()
      );
    if (!smtpResolvedForResponse) {
      logInvoiceSmtpDiagnostics(
        "recreateInvoiceForPayment",
        smtpForDiagnostics
      );
    }

    return {
      ok: true,
      newInvoiceId: invoiceRef.id,
      newInvoiceNumber: invoiceNumber,
      invoiceYear:
        typeof year === "number" && !Number.isNaN(year)
          ? year
          : yearFromInvoiceNumber(invoiceNumber),
      paymentId,
      smtpDiagnostics: smtpDiagnosticsPayload(smtpForDiagnostics),
    };
  }
);
