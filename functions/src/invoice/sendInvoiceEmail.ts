import nodemailer from "nodemailer";
import {
  EMAIL_BODY_TEXT,
  EMAIL_SUBJECT,
  INVOICE_BRAND,
} from "./constants";

export interface SendInvoiceEmailsResult {
  attempted: boolean;
  sent: boolean;
  error?: string;
}

/** Trim + strip accidental spaces/newlines (common when pasting App Passwords). */
function normalizeSmtpAuth(user: string, pass: string): { user: string; pass: string } {
  const u = user.trim();
  const p = pass.trim().replace(/\s+/g, "");
  return { user: u, pass: p };
}

export async function sendInvoiceEmails(params: {
  smtp: { host: string; port: number; user: string; pass: string };
  companyEmail: string | null;
  pdfBuffer: Buffer;
  pdfFileName: string;
}): Promise<SendInvoiceEmailsResult> {
  const { smtp, companyEmail, pdfBuffer, pdfFileName } = params;
  const { user: smtpUser, pass: smtpPass } = normalizeSmtpAuth(smtp.user, smtp.pass);

  if (!smtpPass || !smtpUser) {
    return { attempted: false, sent: false };
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

    const adminEmail = INVOICE_BRAND.adminCopyEmail;
    const recipients = new Set<string>();
    if (companyEmail && companyEmail.includes("@")) {
      recipients.add(companyEmail.trim().toLowerCase());
    }
    recipients.add(adminEmail.trim().toLowerCase());

    for (const to of recipients) {
      await transporter.sendMail({
        from,
        to,
        subject: EMAIL_SUBJECT,
        text: EMAIL_BODY_TEXT,
        attachments: [attachment],
      });
    }
    return { attempted: true, sent: true };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (/535|badcredentials|invalid login/i.test(msg)) {
      console.error(
        JSON.stringify({
          tag: "invoice_smtp_auth_failed",
          authUser: smtpUser,
          hint: "Use a Gmail App Password for aqaraiapp@gmail.com in secret INVOICE_SMTP_PASS; redeploy after secrets:set",
        })
      );
    }
    return { attempted: true, sent: false, error: msg };
  }
}
