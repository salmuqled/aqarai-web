/**
 * Admin HTTPS callables: resend invoice email, retry PDF generation.
 */
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret, defineString } from "firebase-functions/params";

import { commitFinalizePaidAndLedger } from "./finalizePaidAndLedger";
import {
  applyPdfSuccessToInvoice,
  generateUploadInvoicePdf,
} from "./invoicePdfPipeline";
import { resolvePaymentInvoiceContext } from "./resolvePaymentInvoiceContext";
import { sendInvoiceEmails } from "./sendInvoiceEmail";

const invoiceSmtpPass = defineSecret("INVOICE_SMTP_PASS");
const invoiceSmtpHost = defineString("INVOICE_SMTP_HOST", {
  default: "smtp.gmail.com",
});
const invoiceSmtpPort = defineString("INVOICE_SMTP_PORT", { default: "465" });
const invoiceSmtpUser = defineString("INVOICE_SMTP_USER", {
  default: "aqaraiapp@gmail.com",
});

function assertAdmin(request: { auth?: { token?: Record<string, unknown> } }) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }
  if (request.auth.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
}

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

async function loadInvoiceOrThrow(
  db: admin.firestore.Firestore,
  invoiceId: string
): Promise<{
  ref: admin.firestore.DocumentReference;
  data: Record<string, unknown>;
}> {
  const ref = db.collection("invoices").doc(invoiceId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Invoice not found");
  }
  return { ref, data: snap.data()! };
}

async function downloadPdfBufferForInvoice(
  data: Record<string, unknown>
): Promise<Buffer> {
  const storagePath = str(data.pdfStoragePath);
  if (storagePath) {
    const bucket = admin.storage().bucket();
    const [buf] = await bucket.file(storagePath).download();
    return buf;
  }
  const url = str(data.pdfUrl);
  if (url.startsWith("http")) {
    const res = await fetch(url);
    if (!res.ok) {
      throw new HttpsError(
        "failed-precondition",
        "Could not download PDF from URL"
      );
    }
    const ab = await res.arrayBuffer();
    return Buffer.from(ab);
  }
  throw new HttpsError(
    "failed-precondition",
    "No PDF available — use retryInvoicePdf first"
  );
}

export const resendInvoiceEmail = onCall(
  {
    region: "us-central1",
    secrets: [invoiceSmtpPass],
    timeoutSeconds: 120,
  },
  async (request) => {
    assertAdmin(request);
    const invoiceId = str((request.data as { invoiceId?: string })?.invoiceId);
    if (!invoiceId) {
      throw new HttpsError("invalid-argument", "invoiceId is required");
    }

    const db = admin.firestore();
    const { ref, data } = await loadInvoiceOrThrow(db, invoiceId);
    if (str(data.status) === "cancelled") {
      throw new HttpsError("failed-precondition", "Invoice is cancelled");
    }

    const buf = await downloadPdfBufferForInvoice(data);

    const pass = invoiceSmtpPass.value();
    const user = invoiceSmtpUser.value();
    const host = invoiceSmtpHost.value();
    const port = parseInt(invoiceSmtpPort.value(), 10) || 465;

    const paymentId = str(data.paymentId);
    let companyEmail: string | null = null;
    if (paymentId) {
      const paySnap = await db
        .collection("company_payments")
        .doc(paymentId)
        .get();
      const pay = paySnap.data() as Record<string, unknown> | undefined;
      if (pay) {
        const ctx = await resolvePaymentInvoiceContext(paymentId, pay);
        companyEmail = ctx?.companyEmail ?? null;
      }
    }

    const invoiceNumber = str(data.invoiceNumber);
    const emailResult = await sendInvoiceEmails({
      smtp: { host, port, user, pass },
      companyEmail,
      pdfBuffer: buf,
      pdfFileName: `${invoiceNumber || invoiceId}.pdf`,
    });

    const patch: Record<string, unknown> = {
      emailAttemptAt: FieldValue.serverTimestamp(),
      emailSent: emailResult.sent,
    };
    if (emailResult.sent) {
      patch.emailSentAt = FieldValue.serverTimestamp();
      patch.emailError = FieldValue.delete();
    } else if (emailResult.error) {
      patch.emailError = emailResult.error;
    }

    await ref.update(patch);

    return {
      ok: true,
      emailSent: emailResult.sent,
      error: emailResult.error ?? null,
    };
  }
);

export const retryInvoicePdf = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 120,
    memory: "512MiB",
  },
  async (request) => {
    assertAdmin(request);
    const invoiceId = str((request.data as { invoiceId?: string })?.invoiceId);
    if (!invoiceId) {
      throw new HttpsError("invalid-argument", "invoiceId is required");
    }

    const db = admin.firestore();
    const { ref, data } = await loadInvoiceOrThrow(db, invoiceId);
    const status = str(data.status);
    if (status === "cancelled") {
      throw new HttpsError("failed-precondition", "Invoice is cancelled");
    }

    const paymentId = str(data.paymentId);
    if (!paymentId) {
      throw new HttpsError("failed-precondition", "paymentId missing on invoice");
    }

    const paySnap = await db.collection("company_payments").doc(paymentId).get();
    if (!paySnap.exists) {
      throw new HttpsError("not-found", "Payment not found");
    }
    const pay = paySnap.data() as Record<string, unknown>;

    const ctx = await resolvePaymentInvoiceContext(paymentId, pay);
    if (!ctx) {
      throw new HttpsError(
        "failed-precondition",
        "Could not resolve invoice context"
      );
    }

    await commitFinalizePaidAndLedger(db, ref, paymentId);

    const invoiceNumber = str(data.invoiceNumber);
    if (!invoiceNumber) {
      throw new HttpsError("failed-precondition", "invoiceNumber missing");
    }
    const y =
      typeof data.invoiceYear === "number" && !Number.isNaN(data.invoiceYear)
        ? (data.invoiceYear as number)
        : yearFromInvoiceNumber(invoiceNumber);

    const pdfStatus = status === "paid" ? "paid" : "issued";

    try {
      const { pdfUrl, pdfStoragePath } = await generateUploadInvoicePdf({
        invoiceNumber,
        year: y,
        ctx,
        invoiceStatusForPdf: pdfStatus,
      });
      await applyPdfSuccessToInvoice(ref, pdfUrl, pdfStoragePath);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      await ref.update({
        pdfError: msg,
        pdfErrorAt: FieldValue.serverTimestamp(),
      });
      throw new HttpsError("internal", msg);
    }

    return { ok: true };
  }
);
