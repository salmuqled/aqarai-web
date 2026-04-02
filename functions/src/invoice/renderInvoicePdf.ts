/**
 * Invoice PDF via HTML → Puppeteer (puppeteer-core + @sparticuz/chromium for Cloud Functions).
 * Deploy: callers should use sufficient memory (e.g. 1GiB) and timeout for cold Chromium.
 */
import * as admin from "firebase-admin";
import * as fs from "fs";
import * as path from "path";
import puppeteer from "puppeteer-core";
import chromium from "@sparticuz/chromium";
import type { Browser } from "puppeteer-core";

import { INVOICE_BRAND, FOOTER_THANKS } from "./constants";
import { areaDisplayEnglish } from "./invoicePdfAreaEn";
import type { InvoiceServiceType, PaymentInvoiceContext } from "./resolvePaymentInvoiceContext";

function assetsDir(): string {
  return path.join(__dirname, "../../assets");
}

function formatKwd(amount: number): string {
  const n = Number.isFinite(amount) ? amount : 0;
  const parts = n.toLocaleString("en-US", {
    minimumFractionDigits: 3,
    maximumFractionDigits: 3,
  });
  return `${parts} KWD`;
}

/** Primary line item description (commercial wording). */
function serviceDescriptionLine(t: InvoiceServiceType): string {
  switch (t) {
    case "rent":
      return "Property Rental Service";
    case "chalet":
      return "Chalet Booking Service";
    default:
      return "Property Sale Service";
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function trimStr(v: unknown): string {
  if (v == null) return "";
  return String(v).trim();
}

function billToFieldsFromCtx(ctx: PaymentInvoiceContext): {
  name: string;
  email: string;
} {
  return {
    name: (ctx.companyName || "").trim(),
    email: (ctx.companyEmail || "").trim(),
  };
}

/** Safe HTML for `.bill-to` (text escaped; markup is ours only). */
function formatBillToHtml(name: string, email: string): string {
  const n = name.trim();
  const e = email.trim();
  if (n && e) {
    return `${escapeHtml(n)}<div class="bill-to-email">${escapeHtml(e)}</div>`;
  }
  if (e) return escapeHtml(e);
  if (n) return escapeHtml(n);
  return escapeHtml("Valued Customer");
}

/**
 * BILL TO: `company_payments` → userId → `users` name/email, else ctx fields.
 */
async function resolveBillToFields(
  paymentId: string | undefined,
  ctx: PaymentInvoiceContext
): Promise<{ name: string; email: string }> {
  const fromCtx = (): { name: string; email: string } => billToFieldsFromCtx(ctx);
  const id = paymentId?.trim();
  if (!id) return fromCtx();

  try {
    const db = admin.firestore();
    const paySnap = await db.collection("company_payments").doc(id).get();
    if (!paySnap.exists) return fromCtx();
    const pay = paySnap.data() as Record<string, unknown> | undefined;
    const userId = trimStr(pay?.userId) || trimStr(pay?.createdBy);
    if (!userId) return fromCtx();

    const userSnap = await db.collection("users").doc(userId).get();
    const ud = userSnap.data();
    const user =
      userSnap.exists && ud
        ? {
            name: trimStr(
              ud.name ?? ud.fullName ?? ud.displayName ?? ud.userName
            ),
            email: trimStr(ud.email),
          }
        : null;

    if (!user) return fromCtx();
    const name = user.name || "";
    const email = user.email || "";
    if (!name && !email) return fromCtx();
    return { name, email };
  } catch (e) {
    console.error("renderInvoicePdf: BILL TO Firestore lookup failed", e);
    return fromCtx();
  }
}

/** 1×1 transparent PNG */
const FALLBACK_LOGO_DATA_URI =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

function loadLogoDataUri(): string {
  const logoPath = path.join(
    assetsDir(),
    "images",
    "aqarai_logo_transparent.png"
  );
  try {
    if (fs.existsSync(logoPath)) {
      const buf = fs.readFileSync(logoPath);
      return `data:image/png;base64,${buf.toString("base64")}`;
    }
  } catch {
    /* ignore */
  }
  return FALLBACK_LOGO_DATA_URI;
}

/**
 * HTML layout tokens — replaced before Puppeteer render.
 * (Exported for previews/tests; PDF path uses `buildInvoiceHtml`.)
 */
export const INVOICE_HTML_TEMPLATE_REFERENCE = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Invoice __INVOICE_NUMBER__</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      background: #f4f6f8;
      color: #111827;
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }
    .page-watermark {
      position: fixed;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%) rotate(-15deg);
      opacity: 0.05;
      width: 800px;
      z-index: 0;
      pointer-events: none;
    }
    .page-watermark img {
      width: 100%;
      height: auto;
      object-fit: contain;
    }
    .container {
      position: relative;
      z-index: 1;
    }
    .page {
      max-width: 720px;
      margin: 24px auto;
      padding: 40px;
    }
    .card {
      background: rgba(255, 255, 255, 0.85);
      border-radius: 16px;
      padding: 40px;
      box-shadow: 0 4px 24px rgba(15, 23, 42, 0.08), 0 1px 3px rgba(15, 23, 42, 0.06);
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 24px;
      margin-bottom: 32px;
    }
    .brand {
      display: flex;
      align-items: flex-start;
      gap: 14px;
    }
    .brand img { display: block; flex-shrink: 0; }
    .brand-title { font-size: 1.25rem; font-weight: 700; color: #0D2B4D; line-height: 1.2; }
    .brand-email { font-size: 0.875rem; color: #64748b; margin-top: 6px; }
    .invoice-meta { text-align: right; }
    .invoice-meta .label-big {
      font-size: 1.75rem;
      font-weight: 700;
      color: #0D2B4D;
      letter-spacing: -0.02em;
    }
    .invoice-meta .num { font-size: 1rem; font-weight: 700; color: #0D2B4D; margin-top: 8px; }
    .invoice-meta .date { font-size: 0.9375rem; color: #374151; margin-top: 6px; }
    .section-label { font-size: 0.65rem; font-weight: 700; color: #64748b; text-transform: uppercase; letter-spacing: 0.06em; margin-bottom: 8px; }
    .bill-to { margin-bottom: 28px; font-size: 1rem; font-weight: 500; }
    .bill-to-email { font-size: 0.875rem; font-weight: 400; color: #64748b; margin-top: 6px; }
    .table-wrap { border: 1px solid #e2e8f0; border-radius: 8px; overflow: hidden; margin-bottom: 28px; }
    .table-head { display: flex; background: #f1f5f9; font-size: 0.65rem; font-weight: 700; color: #64748b; text-transform: uppercase; letter-spacing: 0.05em; }
    .table-head > div { padding: 12px 16px; }
    .th-desc { flex: 1; }
    .th-amt { width: 140px; text-align: right; }
    .table-row { display: flex; border-top: 1px solid #e2e8f0; font-size: 0.9375rem; }
    .table-row > div { padding: 16px; }
    .td-desc { flex: 1; }
    .td-desc .sub { font-size: 0.8125rem; color: #64748b; margin-top: 6px; line-height: 1.45; }
    .td-desc .line-item-lines .sub { display: block; margin-top: 4px; }
    .td-desc .line-item-lines .sub:first-child { margin-top: 6px; }
    .td-amt { width: 140px; text-align: right; font-weight: 500; align-self: flex-start; }
    .total-row { display: flex; justify-content: space-between; align-items: center; padding-top: 20px; margin-top: 8px; border-top: 2px solid #e2e8f0; }
    .total-label { font-size: 0.875rem; font-weight: 700; color: #0D2B4D; }
    .total-amt { font-size: 1.5rem; font-weight: 700; color: #0D2B4D; }
    .status-wrap { margin-top: 24px; }
    .badge-paid {
      display: inline-block;
      background: #dcfce7;
      color: #15803d;
      font-weight: 700;
      font-size: 0.8125rem;
      padding: 8px 14px;
      border-radius: 999px;
    }
    .footer { text-align: center; margin-top: 36px; font-size: 0.8125rem; color: #94a3b8; }
  </style>
</head>
<body>
  <div class="page-watermark" aria-hidden="true">
    <img src="__LOGO_DATA_URI__" alt="" />
  </div>
  <div class="container">
  <div class="page">
    <div class="card">
      <div class="header">
        <div class="brand">
          <img src="__LOGO_DATA_URI__" style="width:50px;height:50px;" alt="Logo" />
          <div>
            <div class="brand-title">__BRAND_NAME__</div>
            <div class="brand-email">__BRAND_EMAIL__</div>
          </div>
        </div>
        <div class="invoice-meta">
          <div class="label-big">INVOICE</div>
          <div class="num">__INVOICE_NUMBER__</div>
          <div class="date">__DATE__</div>
        </div>
      </div>

      <div class="section-label">Bill to</div>
      <div class="bill-to">__BILL_TO__</div>

      <div class="section-label" style="margin-bottom:10px;">Line items</div>
      <div class="table-wrap">
        <div class="table-head">
          <div class="th-desc">Description</div>
          <div class="th-amt">Amount</div>
        </div>
        <div class="table-row">
          <div class="td-desc">
            <strong>__SERVICE_DESCRIPTION__</strong>
            <div class="line-item-lines">__LINE_ITEM_DETAILS__</div>
          </div>
          <div class="td-amt">__AMOUNT_FORMATTED__</div>
        </div>
      </div>

      <div class="total-row">
        <span class="total-label">Total</span>
        <span class="total-amt">__AMOUNT_FORMATTED__</span>
      </div>

      <div class="status-wrap">
        <span class="badge-paid">__STATUS__</span>
      </div>

      <div class="footer">__FOOTER__</div>
    </div>
  </div>
  </div>
</body>
</html>`;

function lineItemDetailDash(s: string): string {
  return s.trim().length > 0 ? s.trim() : "—";
}

function buildLineItemDetailsHtml(
  areaDisplay: string,
  ctx: PaymentInvoiceContext
): string {
  const lines = [
    `Area — ${lineItemDetailDash(areaDisplay)}`,
    `Type — ${lineItemDetailDash(ctx.propertyType)}`,
    `Block — ${lineItemDetailDash(ctx.block)}`,
    `Street — ${lineItemDetailDash(ctx.street)}`,
    `Property Price — ${lineItemDetailDash(ctx.propertyPrice)}`,
  ];
  return lines
    .map((line) => `<div class="sub">${escapeHtml(line)}</div>`)
    .join("");
}

function buildInvoiceHtml(params: {
  invoiceNumber: string;
  date: string;
  billToHtml: string;
  serviceDescription: string;
  lineItemDetailsHtml: string;
  amountFormatted: string;
  statusLine: string;
  logoDataUri: string;
}): string {
  const m: Record<string, string> = {
    __INVOICE_NUMBER__: escapeHtml(params.invoiceNumber),
    __DATE__: escapeHtml(params.date),
    __BILL_TO__: params.billToHtml,
    __SERVICE_DESCRIPTION__: escapeHtml(params.serviceDescription),
    __LINE_ITEM_DETAILS__: params.lineItemDetailsHtml,
    __AMOUNT_FORMATTED__: escapeHtml(params.amountFormatted),
    __STATUS__: escapeHtml(params.statusLine),
    __LOGO_DATA_URI__: params.logoDataUri,
    __BRAND_NAME__: escapeHtml(INVOICE_BRAND.appName),
    __BRAND_EMAIL__: escapeHtml(INVOICE_BRAND.contactEmail),
    __FOOTER__: escapeHtml(FOOTER_THANKS),
  };
  let html = INVOICE_HTML_TEMPLATE_REFERENCE;
  for (const [token, value] of Object.entries(m)) {
    html = html.split(token).join(value);
  }
  return html;
}

export async function renderInvoicePdfBuffer(params: {
  invoiceNumber: string;
  invoiceDate: Date;
  ctx: PaymentInvoiceContext;
  /** e.g. PAID | ISSUED | CANCELLED */
  statusLine: string;
  /** When set, BILL TO prefers `users/{userId}` from this payment doc. */
  paymentId?: string;
}): Promise<Buffer> {
  const { invoiceNumber, invoiceDate, ctx, statusLine, paymentId } = params;

  const date = invoiceDate.toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "Asia/Kuwait",
  });

  const billFields = await resolveBillToFields(paymentId, ctx);
  const billToHtml = formatBillToHtml(billFields.name, billFields.email);

  const areaEn = areaDisplayEnglish(ctx.area);
  const lineItemDesc = serviceDescriptionLine(ctx.serviceType);
  const serviceDescription = lineItemDesc;
  const lineItemDetailsHtml = buildLineItemDetailsHtml(areaEn, ctx);
  const amountFormatted = formatKwd(ctx.amount);

  const html = buildInvoiceHtml({
    invoiceNumber,
    date,
    billToHtml,
    serviceDescription,
    lineItemDetailsHtml,
    amountFormatted,
    statusLine,
    logoDataUri: loadLogoDataUri(),
  });

  return renderHtmlToPdfBuffer(html, `Invoice ${invoiceNumber}`);
}

async function renderHtmlToPdfBuffer(
  html: string,
  documentTitle: string
): Promise<Buffer> {
  let browser: Browser | undefined;
  try {
    // @sparticuz/chromium v141+ no longer exposes `chromium.headless`; use shell mode (see package README).
    browser = await puppeteer.launch({
      args: chromium.args,
      executablePath: await chromium.executablePath(),
      headless: "shell",
    });
    const page = await browser.newPage();
    await page.setContent(html, {
      waitUntil: "load",
      timeout: 30_000,
    });
    await new Promise<void>((resolve) => setTimeout(resolve, 300));
    await page.evaluate((t) => {
      document.title = t;
    }, documentTitle);

    const pdfBuffer = await page.pdf({
      format: "A4",
      printBackground: true,
    });

    return Buffer.from(pdfBuffer);
  } catch (err) {
    console.error("renderInvoicePdf: Puppeteer PDF generation failed", err);
    throw err;
  } finally {
    await browser?.close();
  }
}
