/** Brand + email defaults for automated invoices (PDF + SMTP). */
export const INVOICE_BRAND = {
  appName: "AqarAi App",
  primaryNavy: "#0D2B4D",
  contactEmail: "aqaraiapp@gmail.com",
  adminCopyEmail: "aqaraiapp@gmail.com",
} as const;

export const EMAIL_SUBJECT = "Invoice from AqarAi App";
export const EMAIL_BODY_TEXT =
  "Your payment has been received. Please find attached your invoice.";

export const FOOTER_THANKS = "Thank you for using AqarAi App";
