/**
 * Invoice SMTP: password from Secret Manager only (`INVOICE_SMTP_PASS`).
 * Auth user is fixed to the project Gmail mailbox so `.env` / params cannot mismatch App Password.
 *
 * After rotating the secret, redeploy every function that lists `secrets: [invoiceSmtpPass]`:
 *   onCompanyPaymentConfirmedInvoice, resendInvoiceEmail, recreateInvoiceForPayment
 */

/** Must match the Google account used to create the App Password. */
export const INVOICE_SMTP_AUTH_USER = "aqaraiapp@gmail.com";

export interface InvoiceSmtpResolved {
  host: string;
  port: number;
  user: string;
  pass: string;
}

/**
 * Resolves host/port from params; auth user is always [INVOICE_SMTP_AUTH_USER];
 * pass from secret (trimmed, spaces stripped).
 */
export function resolveInvoiceSmtp(
  hostRaw: string,
  portRaw: string,
  passRaw: string
): InvoiceSmtpResolved {
  const host = (hostRaw || "smtp.gmail.com").trim();
  const port = parseInt((portRaw || "465").trim(), 10) || 465;
  const user = INVOICE_SMTP_AUTH_USER;
  const pass = passRaw.trim().replace(/\s+/g, "");
  return { host, port, user, pass };
}

/** Safe to return to admin callables (no password). */
export function smtpDiagnosticsPayload(
  smtp: InvoiceSmtpResolved
): Record<string, unknown> {
  return {
    authUser: smtp.user,
    userMatchesExpectedAqaraiApp: smtp.user === INVOICE_SMTP_AUTH_USER,
    appPasswordCharCount: smtp.pass.length,
    secretConfigured: smtp.pass.length > 0,
    host: smtp.host,
    port: smtp.port,
  };
}

/**
 * Logs non-secret fields + pass length only (never logs password bytes).
 */
export function logInvoiceSmtpDiagnostics(
  context: string,
  smtp: InvoiceSmtpResolved
): void {
  const payload = {
    tag: "invoice_smtp_diagnostics",
    context,
    ...smtpDiagnosticsPayload(smtp),
  };
  console.log(JSON.stringify(payload));

  if (smtp.pass.length === 0) {
    console.warn(
      `[invoice_smtp] context=${context} INVOICE_SMTP_PASS is empty — set secret via: firebase functions:secrets:set INVOICE_SMTP_PASS`
    );
  } else if (smtp.pass.length !== 16) {
    console.warn(
      `[invoice_smtp] context=${context} Gmail App Passwords are 16 characters (after removing spaces); got length=${smtp.pass.length}.`
    );
  }
}

/** @deprecated alias */
export const INVOICE_SMTP_EXPECTED_USER = INVOICE_SMTP_AUTH_USER;
