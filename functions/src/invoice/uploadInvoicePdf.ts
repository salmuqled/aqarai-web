import { randomUUID } from "crypto";
import * as admin from "firebase-admin";

/**
 * Uploads PDF and returns a Firebase download URL (token metadata).
 */
export async function uploadInvoicePdfAndGetUrl(params: {
  buffer: Buffer;
  storagePath: string;
}): Promise<{ pdfUrl: string; pdfStoragePath: string }> {
  const { buffer, storagePath } = params;
  const bucket = admin.storage().bucket();
  const token = randomUUID();
  const file = bucket.file(storagePath);

  await file.save(buffer, {
    resumable: false,
    metadata: {
      contentType: "application/pdf",
      cacheControl: "private, max-age=3600",
      metadata: {
        firebaseStorageDownloadTokens: token,
      },
    },
  });

  const bucketName = bucket.name;
  const encoded = encodeURIComponent(storagePath);
  const pdfUrl = `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/${encoded}?alt=media&token=${token}`;

  return { pdfUrl, pdfStoragePath: storagePath };
}
