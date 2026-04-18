/**
 * Central exception / incident log (Firestore). Written by Cloud Functions only.
 */
import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";

export type ExceptionSeverity = "low" | "medium" | "high";

export type ExceptionType = "invoice_pdf_failed" | "email_failed" | "ledger_error";

export async function writeExceptionLog(args: {
  type: ExceptionType;
  relatedId: string;
  message: string;
  severity: ExceptionSeverity;
}): Promise<void> {
  const relatedId = (args.relatedId ?? "").trim().slice(0, 800);
  const message = (args.message ?? "").trim().slice(0, 4000);
  if (!relatedId) return;
  try {
    await admin.firestore().collection("exception_logs").add({
      type: args.type,
      relatedId,
      message: message.length > 0 ? message : "(no message)",
      severity: args.severity,
      createdAt: FieldValue.serverTimestamp(),
      resolved: false,
    });
  } catch (e) {
    console.error("[exception_logs] write failed", e);
  }
}
