import nodemailer from "nodemailer";

import { EMAIL_BODY_TEXT, INVOICE_BRAND } from "../invoice/constants";
import {
  type InvoiceSmtpResolved,
} from "../invoice/invoiceSmtpRuntime";

export interface SendBookingInvoiceEmailResult {
  attempted: boolean;
  sent: boolean;
  error?: string;
}

export async function sendBookingInvoiceEmail(params: {
  smtp: InvoiceSmtpResolved;
  to: string | null;
  bccAdmin: boolean;
  ccOwnerEmail?: string | null;
  subject: string;
  bodyText?: string;
  pdfBuffer: Buffer;
  pdfFileName: string;
}): Promise<SendBookingInvoiceEmailResult> {
  const {
    smtp,
    to,
    bccAdmin,
    ccOwnerEmail,
    subject,
    bodyText,
    pdfBuffer,
    pdfFileName,
  } = params;

  const smtpUser = smtp.user.trim();
  const smtpPass = smtp.pass.trim().replace(/\s+/g, "");
  if (!smtpUser || !smtpPass) {
    return { attempted: false, sent: false };
  }

  const toEmail = (to || "").trim().toLowerCase();
  if (!toEmail || !toEmail.includes("@")) {
    // No client email; still attempt to send to admin copy if requested.
    if (!bccAdmin) return { attempted: false, sent: false };
  }

  try {
    const transporter = nodemailer.createTransport({
      host: smtp.host.trim(),
      port: smtp.port,
      secure: smtp.port === 465,
      auth: { user: smtpUser, pass: smtpPass },
    });

    const from = `"${INVOICE_BRAND.appName}" <${smtpUser}>`;
    const attachment = {
      filename: pdfFileName,
      content: pdfBuffer,
      contentType: "application/pdf",
    };

    const bcc = bccAdmin ? INVOICE_BRAND.adminCopyEmail : undefined;
    const cc = ccOwnerEmail && ccOwnerEmail.includes("@") ? ccOwnerEmail : undefined;

    await transporter.sendMail({
      from,
      to: toEmail || undefined,
      subject,
      text: bodyText || EMAIL_BODY_TEXT,
      attachments: [attachment],
      bcc: bcc ? bcc.trim().toLowerCase() : undefined,
      cc: cc ? cc.trim().toLowerCase() : undefined,
    });

    return { attempted: true, sent: true };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { attempted: true, sent: false, error: msg };
  }
}

