/**
 * When a company payment becomes confirmed: invoice (issued) → paid + ledger → PDF → email.
 * Does not write payment_logs (handled elsewhere).
 */
import * as admin from "firebase-admin";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { defineSecret, defineString } from "firebase-functions/params";
import { FieldValue } from "firebase-admin/firestore";

import { allocateInvoiceInTransaction } from "./invoice/allocateInvoice";
import { commitFinalizePaidAndLedger } from "./invoice/finalizePaidAndLedger";
import {
  applyPdfSuccessToInvoice,
  generateUploadInvoicePdf,
} from "./invoice/invoicePdfPipeline";
import { resolvePaymentInvoiceContext } from "./invoice/resolvePaymentInvoiceContext";
import {
  logInvoiceSmtpDiagnostics,
  resolveInvoiceSmtp,
} from "./invoice/invoiceSmtpRuntime";
import { sendInvoiceEmails } from "./invoice/sendInvoiceEmail";
import { writeExceptionLog } from "./exceptionLogs";

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

async function resolveExistingInvoiceJob(
  db: admin.firestore.Firestore,
  paymentId: string
): Promise<{
  invoiceRef: admin.firestore.DocumentReference;
  invoiceNumber: string;
  year: number;
} | null> {
  const snap = await db
    .collection("invoices")
    .where("paymentId", "==", paymentId)
    .limit(1)
    .get();
  if (snap.empty) return null;
  const doc = snap.docs[0];
  const d = doc.data();
  const pdfUrl = str(d.pdfUrl);
  if (pdfUrl.length > 8) {
    return null;
  }
  const invoiceNumber = str(d.invoiceNumber);
  if (!invoiceNumber) return null;
  const y =
    typeof d.invoiceYear === "number" && !Number.isNaN(d.invoiceYear)
      ? d.invoiceYear
      : yearFromInvoiceNumber(invoiceNumber);
  return { invoiceRef: doc.ref, invoiceNumber, year: y };
}

export const onCompanyPaymentConfirmedInvoice = onDocumentWritten(
  {
    document: "company_payments/{paymentId}",
    region: "us-central1",
    secrets: [invoiceSmtpPass],
    timeoutSeconds: 180,
    memory: "1GiB",
  },
  async (event) => {
    const paymentId = event.params.paymentId;
    if (!paymentId) return;

    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!after) return;

    if (str(after.status) !== "confirmed") return;
    if (before !== undefined && str(before.status) === "confirmed") return;

    const db = admin.firestore();
    const payment = after as Record<string, unknown>;

    const ctx = await resolvePaymentInvoiceContext(paymentId, payment);
    if (!ctx) {
      console.warn(
        "onCompanyPaymentConfirmedInvoice: skip (no invoice context)",
        paymentId
      );
      return;
    }

    const allocated = await allocateInvoiceInTransaction(
      db,
      paymentId,
      () => ({
        companyId: ctx.companyId,
        companyName: ctx.companyName,
        amount: ctx.amount,
        serviceType: ctx.serviceType,
        area: ctx.area,
        description: ctx.descriptionAr,
        status: "issued",
        emailSent: false,
      })
    );

    let invoiceRef: admin.firestore.DocumentReference;
    let invoiceNumber: string;
    let year: number;

    if (allocated) {
      invoiceRef = allocated.invoiceRef;
      invoiceNumber = allocated.invoiceNumber;
      year = allocated.year;
    } else {
      const resume = await resolveExistingInvoiceJob(db, paymentId);
      if (!resume) {
        return;
      }
      ({ invoiceRef, invoiceNumber, year } = resume);
    }

    await commitFinalizePaidAndLedger(db, invoiceRef, paymentId);

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

      const smtpResolved = resolveInvoiceSmtp(
        invoiceSmtpHost.value(),
        invoiceSmtpPort.value(),
        invoiceSmtpPass.value()
      );
      logInvoiceSmtpDiagnostics("onCompanyPaymentConfirmedInvoice", smtpResolved);

      const emailResult = await sendInvoiceEmails({
        smtp: smtpResolved,
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
          "onCompanyPaymentConfirmedInvoice: SMTP not configured; PDF stored only."
        );
      }
    } catch (err) {
      console.error(
        "onCompanyPaymentConfirmedInvoice: PDF/email pipeline failed",
        paymentId,
        err
      );
      void writeExceptionLog({
        type: "invoice_pdf_failed",
        relatedId: paymentId,
        message: `company payment: ${str((err as Error)?.message) || "pdf_or_email_failed"}`,
        severity: "high",
      });
      await invoiceRef.update({
        pdfError: str((err as Error)?.message) || "pdf_or_email_failed",
        pdfErrorAt: FieldValue.serverTimestamp(),
      });
    }
  }
);
