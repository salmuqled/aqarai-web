import * as admin from "firebase-admin";
import { randomUUID } from "crypto";

export async function uploadBookingInvoicePdfAndGetUrl(params: {
  buffer: Buffer;
  bookingId: string;
}): Promise<{ pdfUrl: string; pdfStoragePath: string }> {
  const { buffer, bookingId } = params;
  const bid = bookingId.trim();
  const storagePath = `invoices/${bid}.pdf`;
  const bucket = admin.storage().bucket();
  const token = randomUUID();
  const file = bucket.file(storagePath);

  await file.save(buffer, {
    resumable: false,
    metadata: {
      contentType: "application/pdf",
      cacheControl: "private, max-age=3600",
      metadata: { firebaseStorageDownloadTokens: token },
    },
  });

  const bucketName = bucket.name;
  const encoded = encodeURIComponent(storagePath);
  const pdfUrl = `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/${encoded}?alt=media&token=${token}`;
  return { pdfUrl, pdfStoragePath: storagePath };
}

