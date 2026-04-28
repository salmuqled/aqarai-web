/**
 * Post-payment pipeline for «feature my listing»: Firestore invoice + PDF + SMTP.
 * Best-effort: callers (e.g. featurePropertyPaid) must not fail the payment if this throws.
 */
import {
  FieldValue,
  Timestamp,
  type DocumentReference,
  type Firestore,
} from "firebase-admin/firestore";

import { allocateInvoiceInTransaction } from "./allocateInvoice";
import { commitFinalizePaidAndLedger } from "./finalizePaidAndLedger";
import {
  applyPdfSuccessToInvoice,
  generateUploadInvoicePdf,
} from "./invoicePdfPipeline";
import type { PaymentInvoiceContext } from "./resolvePaymentInvoiceContext";
import { sendInvoiceEmails } from "./sendInvoiceEmail";
import { writeExceptionLog } from "../exceptionLogs";

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

export async function issueFeaturedPropertyInvoice(params: {
  db: Firestore;
  paymentId: string;
  propertyId: string;
  durationDays: number;
  newFeaturedUntil: Date;
  amountKwd: number;
  ctx: PaymentInvoiceContext;
  smtp: { host: string; port: number; user: string; pass: string };
  /** Human-readable line for email (e.g. Property Featuring - 7 days). */
  lineTitleEn: string;
}): Promise<{ invoiceId: string; invoiceNumber: string } | null> {
  const {
    db,
    paymentId,
    propertyId,
    durationDays,
    newFeaturedUntil,
    amountKwd,
    ctx,
    smtp,
    lineTitleEn,
  } = params;

  const untilTs = Timestamp.fromDate(newFeaturedUntil);

  const allocated = await allocateInvoiceInTransaction(
    db,
    paymentId,
    () => ({
      companyId: ctx.companyId,
      companyName: ctx.companyName,
      clientId: ctx.clientId,
      amount: amountKwd,
      serviceType: ctx.serviceType,
      area: ctx.area,
      description: ctx.descriptionAr,
      descriptionEn: lineTitleEn,
      status: "issued",
      emailSent: false,
      kind: "property_feature",
      propertyId,
      durationDays,
      featuredUntil: untilTs,
      currency: "KWD",
    })
  );

  let invoiceRef: DocumentReference;
  let invoiceNumber: string;
  let year: number;

  if (allocated) {
    invoiceRef = allocated.invoiceRef;
    invoiceNumber = allocated.invoiceNumber;
    year = allocated.year;
  } else {
    const snap = await db
      .collection("invoices")
      .where("paymentId", "==", paymentId)
      .limit(1)
      .get();
    if (snap.empty) {
      console.warn(
        JSON.stringify({
          tag: "featured_invoice_no_row",
          paymentId,
        })
      );
      return null;
    }
    const doc = snap.docs[0];
    const d = doc.data();
    if (str(d.pdfUrl).length > 8) {
      return {
        invoiceId: doc.id,
        invoiceNumber: str(d.invoiceNumber),
      };
    }
    invoiceNumber = str(d.invoiceNumber);
    if (!invoiceNumber) return null;
    year =
      typeof d.invoiceYear === "number" && !Number.isNaN(d.invoiceYear)
        ? d.invoiceYear
        : yearFromInvoiceNumber(invoiceNumber);
    invoiceRef = doc.ref;
  }

  await commitFinalizePaidAndLedger(db, invoiceRef, paymentId);

  try {
    const { pdfBuffer, pdfUrl, pdfStoragePath } = await generateUploadInvoicePdf(
      {
        invoiceNumber,
        year,
        ctx,
        invoiceStatusForPdf: "paid",
        paymentId,
      }
    );

    await applyPdfSuccessToInvoice(invoiceRef, pdfUrl, pdfStoragePath);

    const untilStr = newFeaturedUntil.toLocaleString("en-GB", {
      timeZone: "Asia/Kuwait",
      dateStyle: "long",
      timeStyle: "short",
    });
    const emailResult = await sendInvoiceEmails({
      smtp,
      companyEmail: ctx.companyEmail,
      pdfBuffer,
      pdfFileName: `${invoiceNumber}.pdf`,
      subject: "AqarAi — featured listing payment receipt",
      bodyText: [
        "Thank you for your payment.",
        "",
        `Service: ${lineTitleEn}`,
        `Amount: ${amountKwd.toFixed(3)} KWD`,
        `Property ID: ${propertyId}`,
        `Featured until: ${untilStr} (Asia/Kuwait)`,
        "",
        "Your invoice (PDF) is attached.",
        "",
        "— AqarAi",
      ].join("\n"),
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
    await invoiceRef.update({
      ...emailPatch,
      fileUrl: pdfUrl,
      status: "paid",
      updatedAt: FieldValue.serverTimestamp(),
    });

    if (!emailResult.attempted) {
      console.warn(
        JSON.stringify({
          tag: "featured_invoice_smtp_not_configured",
          paymentId,
          invoiceId: invoiceRef.id,
        })
      );
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(
      JSON.stringify({
        tag: "featured_invoice_pdf_or_email_failed",
        paymentId,
        invoiceId: invoiceRef.id,
        error: msg,
      })
    );
    void writeExceptionLog({
      type: "invoice_pdf_failed",
      relatedId: paymentId,
      message: `featured: ${msg}`,
      severity: "high",
    });
    await invoiceRef.update({
      pdfError: msg || "pdf_or_email_failed",
      pdfErrorAt: FieldValue.serverTimestamp(),
    });
  }

  return { invoiceId: invoiceRef.id, invoiceNumber };
}
