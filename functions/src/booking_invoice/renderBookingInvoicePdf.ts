/**
 * Booking invoice PDF via HTML → Puppeteer.
 * Kept separate from company payment invoices to avoid coupling to PaymentInvoiceContext.
 */
import * as fs from "fs";
import * as path from "path";
import chromium from "@sparticuz/chromium";
import puppeteer from "puppeteer-core";
import type { Browser } from "puppeteer-core";

import { INVOICE_BRAND, FOOTER_THANKS } from "../invoice/constants";

function assetsDir(): string {
  return path.join(__dirname, "../../assets");
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function formatKwd3(amount: number): string {
  const n = Number.isFinite(amount) ? amount : 0;
  const parts = n.toLocaleString("en-US", {
    minimumFractionDigits: 3,
    maximumFractionDigits: 3,
  });
  return `${parts} KWD`;
}

/** 1×1 transparent PNG */
const FALLBACK_LOGO_DATA_URI =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

function loadLogoDataUri(): string {
  const logoPath = path.join(assetsDir(), "images", "aqarai_logo_transparent.png");
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

function buildBookingInvoiceHtml(params: {
  invoiceNumber: string;
  invoiceDate: Date;
  bookingId: string;
  paymentId: string;
  propertyTitle: string;
  billToName: string;
  billToEmail: string;
  startDate: Date;
  endDate: Date;
  nights: number;
  pricePerNight: number;
  totalAmount: number;
  commissionAmount: number;
  ownerNet: number;
}): string {
  const {
    invoiceNumber,
    invoiceDate,
    bookingId,
    paymentId,
    propertyTitle,
    billToName,
    billToEmail,
    startDate,
    endDate,
    nights,
    pricePerNight,
    totalAmount,
    commissionAmount,
    ownerNet,
  } = params;

  const logo = loadLogoDataUri();
  const safeTitle = escapeHtml(propertyTitle || "Chalet booking");
  const safeBillTo = escapeHtml(billToName || "Valued Customer");
  const safeEmail = escapeHtml(billToEmail || "");
  const dateStr = invoiceDate.toLocaleDateString("en-GB", {
    year: "numeric",
    month: "short",
    day: "2-digit",
    timeZone: "Asia/Kuwait",
  });
  const startStr = startDate.toLocaleDateString("en-GB", {
    year: "numeric",
    month: "short",
    day: "2-digit",
    timeZone: "Asia/Kuwait",
  });
  const endStr = endDate.toLocaleDateString("en-GB", {
    year: "numeric",
    month: "short",
    day: "2-digit",
    timeZone: "Asia/Kuwait",
  });

  const nightsSafe = Math.max(0, Math.round(nights || 0));
  const ppn = formatKwd3(pricePerNight);
  const total = formatKwd3(totalAmount);
  const comm = formatKwd3(commissionAmount);
  const net = formatKwd3(ownerNet);

  const billToHtml =
    safeEmail.length > 0
      ? `${safeBillTo}<div style="font-size:0.875rem;color:#64748b;margin-top:6px;">${safeEmail}</div>`
      : safeBillTo;

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Invoice ${escapeHtml(invoiceNumber)}</title>
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
    .page {
      max-width: 740px;
      margin: 24px auto;
      padding: 40px;
    }
    .card {
      background: rgba(255,255,255,0.92);
      border-radius: 16px;
      padding: 40px;
      box-shadow: 0 4px 24px rgba(15, 23, 42, 0.08), 0 1px 3px rgba(15, 23, 42, 0.06);
    }
    .header { display: flex; justify-content: space-between; gap: 24px; margin-bottom: 28px; }
    .brand { display:flex; gap:14px; align-items:flex-start; }
    .brand-title { font-size: 1.25rem; font-weight: 800; color: ${INVOICE_BRAND.primaryNavy}; line-height: 1.2; }
    .brand-email { font-size: 0.875rem; color: #64748b; margin-top: 6px; }
    .meta { text-align: right; }
    .meta .label { font-size: 1.6rem; font-weight: 800; color: ${INVOICE_BRAND.primaryNavy}; }
    .meta .num { margin-top: 8px; font-weight: 800; color: ${INVOICE_BRAND.primaryNavy}; }
    .meta .date { margin-top: 6px; color: #374151; }
    .section-label { font-size: 0.65rem; font-weight: 800; color: #64748b; text-transform: uppercase; letter-spacing: 0.06em; margin-bottom: 8px; }
    .bill-to { margin-bottom: 22px; font-size: 1rem; font-weight: 600; }
    .table { border: 1px solid #e2e8f0; border-radius: 10px; overflow: hidden; margin-bottom: 22px; }
    .thead { display:flex; background:#f1f5f9; font-size:0.65rem; font-weight:800; color:#64748b; text-transform:uppercase; letter-spacing:0.05em; }
    .thead div { padding: 12px 16px; }
    .th-desc { flex: 1; }
    .th-amt { width: 160px; text-align: right; }
    .row { display:flex; border-top: 1px solid #e2e8f0; }
    .row > div { padding: 16px; }
    .desc { flex: 1; }
    .desc .title { font-weight: 800; color: #0f172a; }
    .desc .sub { margin-top: 6px; font-size: 0.85rem; color: #64748b; line-height: 1.45; }
    .amt { width: 160px; text-align: right; font-weight: 700; }
    .summary { margin-top: 12px; border-top: 2px solid #e2e8f0; padding-top: 16px; }
    .sum-row { display:flex; justify-content: space-between; margin-top: 8px; font-size: 0.95rem; }
    .sum-row strong { color: ${INVOICE_BRAND.primaryNavy}; }
    .total { display:flex; justify-content: space-between; align-items:center; margin-top: 14px; }
    .total .label { font-size: 0.9rem; font-weight: 900; color: ${INVOICE_BRAND.primaryNavy}; }
    .total .value { font-size: 1.5rem; font-weight: 900; color: ${INVOICE_BRAND.primaryNavy}; }
    .footer { text-align:center; margin-top: 28px; font-size: 0.8125rem; color: #94a3b8; }
  </style>
</head>
<body>
  <div class="page">
    <div class="card">
      <div class="header">
        <div class="brand">
          <img src="${logo}" style="width:50px;height:50px;" alt="Logo" />
          <div>
            <div class="brand-title">${escapeHtml(INVOICE_BRAND.appName)}</div>
            <div class="brand-email">${escapeHtml(INVOICE_BRAND.contactEmail)}</div>
          </div>
        </div>
        <div class="meta">
          <div class="label">Invoice</div>
          <div class="num">${escapeHtml(invoiceNumber)}</div>
          <div class="date">${escapeHtml(dateStr)}</div>
        </div>
      </div>

      <div class="section-label">Bill To</div>
      <div class="bill-to">${billToHtml}</div>

      <div class="table">
        <div class="thead">
          <div class="th-desc">Description</div>
          <div class="th-amt">Amount</div>
        </div>
        <div class="row">
          <div class="desc">
            <div class="title">${safeTitle}</div>
            <div class="sub">
              Booking ID: ${escapeHtml(bookingId)}<br/>
              Payment ID: ${escapeHtml(paymentId)}<br/>
              Dates: ${escapeHtml(startStr)} → ${escapeHtml(endStr)} (${nightsSafe} night${nightsSafe === 1 ? "" : "s"})<br/>
              Nightly rate: ${escapeHtml(ppn)}
            </div>
          </div>
          <div class="amt">${escapeHtml(total)}</div>
        </div>
      </div>

      <div class="summary">
        <div class="sum-row"><span>Gross total</span><strong>${escapeHtml(total)}</strong></div>
        <div class="sum-row"><span>Platform commission</span><strong>${escapeHtml(comm)}</strong></div>
        <div class="sum-row"><span>Net to owner</span><strong>${escapeHtml(net)}</strong></div>
        <div class="total">
          <div class="label">Total paid</div>
          <div class="value">${escapeHtml(total)}</div>
        </div>
      </div>

      <div class="footer">${escapeHtml(FOOTER_THANKS)}</div>
    </div>
  </div>
</body>
</html>`;
}

async function launchBrowser(): Promise<Browser> {
  return puppeteer.launch({
    args: chromium.args,
    executablePath: await chromium.executablePath(),
    // @sparticuz/chromium v141+: use "shell" mode.
    headless: "shell",
  });
}

export async function renderBookingInvoicePdfBuffer(params: {
  invoiceNumber: string;
  invoiceDate: Date;
  bookingId: string;
  paymentId: string;
  propertyTitle: string;
  billToName: string;
  billToEmail: string;
  startDate: Date;
  endDate: Date;
  nights: number;
  pricePerNight: number;
  totalAmount: number;
  commissionAmount: number;
  ownerNet: number;
}): Promise<Buffer> {
  const html = buildBookingInvoiceHtml(params);
  let browser: Browser | null = null;
  try {
    browser = await launchBrowser();
    const page = await browser.newPage();
    await page.setContent(html, { waitUntil: "networkidle0" });
    const pdf = await page.pdf({
      format: "A4",
      printBackground: true,
      margin: { top: "18mm", right: "14mm", bottom: "18mm", left: "14mm" },
    });
    return Buffer.from(pdf);
  } finally {
    try {
      await browser?.close();
    } catch {
      /* ignore */
    }
  }
}

