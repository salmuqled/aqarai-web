/**
 * Shared PDF generation + Storage upload for invoice triggers and admin callables.
 */
import { FieldValue } from "firebase-admin/firestore";
import type { DocumentReference } from "firebase-admin/firestore";
import { renderInvoicePdfBuffer } from "./renderInvoicePdf";
import type { PaymentInvoiceContext } from "./resolvePaymentInvoiceContext";
import { uploadInvoicePdfAndGetUrl } from "./uploadInvoicePdf";

export function invoicePdfStatusLabel(status: string): string {
  const s = status.trim().toLowerCase();
  if (s === "paid") return "PAID";
  if (s === "cancelled") return "CANCELLED";
  return "ISSUED";
}

export async function generateUploadInvoicePdf(params: {
  invoiceNumber: string;
  year: number;
  ctx: PaymentInvoiceContext;
  invoiceStatusForPdf: string;
}): Promise<{ pdfBuffer: Buffer; pdfUrl: string; pdfStoragePath: string }> {
  const { invoiceNumber, year, ctx, invoiceStatusForPdf } = params;
  const pdfBuffer = await renderInvoicePdfBuffer({
    invoiceNumber,
    invoiceDate: new Date(),
    ctx,
    statusLine: invoicePdfStatusLabel(invoiceStatusForPdf),
  });
  const storagePath = `invoices/${year}/${invoiceNumber}.pdf`;
  const { pdfUrl, pdfStoragePath } = await uploadInvoicePdfAndGetUrl({
    buffer: pdfBuffer,
    storagePath,
  });
  return { pdfBuffer, pdfUrl, pdfStoragePath };
}

export async function applyPdfSuccessToInvoice(
  invoiceRef: DocumentReference,
  pdfUrl: string,
  pdfStoragePath: string
): Promise<void> {
  await invoiceRef.update({
    pdfUrl,
    pdfStoragePath,
    pdfReadyAt: FieldValue.serverTimestamp(),
    pdfError: FieldValue.delete(),
    pdfErrorAt: FieldValue.delete(),
  });
}
