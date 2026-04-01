import * as fs from "fs";
import * as path from "path";
import PDFDocument from "pdfkit";
import { INVOICE_BRAND, FOOTER_THANKS } from "./constants";
import type { PaymentInvoiceContext } from "./resolvePaymentInvoiceContext";
import { prepareArabicForPdfLine } from "./arabicPdfLine";

const NAVY = "#0D2B4D";

function assetsDir(): string {
  return path.join(__dirname, "../../assets");
}

export function renderInvoicePdfBuffer(params: {
  invoiceNumber: string;
  invoiceDate: Date;
  ctx: PaymentInvoiceContext;
  /** e.g. ISSUED | PAID | CANCELLED */
  statusLine: string;
}): Promise<Buffer> {
  const { invoiceNumber, invoiceDate, ctx, statusLine } = params;
  const logoPath = path.join(
    assetsDir(),
    "images",
    "aqarai_logo_transparent.png"
  );
  const fontPath = path.join(
    assetsDir(),
    "fonts",
    "NotoSansArabic-Regular.ttf"
  );

  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    const doc = new PDFDocument({
      size: "A4",
      margin: 56,
      info: {
        Title: `Invoice ${invoiceNumber}`,
        Author: INVOICE_BRAND.appName,
      },
    });

    doc.on("data", (c) => chunks.push(c as Buffer));
    doc.on("end", () => resolve(Buffer.concat(chunks)));
    doc.on("error", reject);

    const pageW = doc.page.width;
    const margin = 56;
    const contentW = pageW - margin * 2;

    if (fs.existsSync(fontPath)) {
      doc.registerFont("NotoAr", fontPath);
    }

    const hasLogo = fs.existsSync(logoPath);
    const headerTop = doc.y;

    if (hasLogo) {
      try {
        doc.image(logoPath, pageW - margin - 120, headerTop, {
          width: 100,
          fit: [100, 48],
          align: "right",
        });
      } catch {
        // ignore bad image
      }
    }

    doc.fillColor(NAVY).font("Helvetica-Bold").fontSize(20);
    doc.text(INVOICE_BRAND.appName, margin, headerTop, {
      width: contentW - (hasLogo ? 130 : 0),
      align: "left",
    });

    doc.moveDown(0.3);
    doc.font("Helvetica").fontSize(9).fillColor("#445566");
    doc.text(INVOICE_BRAND.contactEmail, { width: contentW, align: "left" });

    doc.moveDown(2.2);
    doc.fillColor(NAVY);

    const dateStr = invoiceDate.toLocaleDateString("en-GB", {
      day: "2-digit",
      month: "short",
      year: "numeric",
      timeZone: "Asia/Kuwait",
    });

    doc.font("Helvetica").fontSize(10);
    doc.text(`Invoice Number: ${invoiceNumber}`, margin);
    doc.moveDown(0.35);
    doc.text(`Date: ${dateStr}`, margin);
    doc.moveDown(1.2);

    doc.font("Helvetica-Bold").fontSize(11).text("Invoice To", margin);
    doc.moveDown(0.25);
    doc.font("Helvetica").fontSize(11).fillColor("#1a1a1a");
    doc.text(ctx.companyName, margin, doc.y, { width: contentW });

    doc.moveDown(1.6);
    doc.fillColor(NAVY).font("Helvetica-Bold").fontSize(10).text("Service", margin);
    doc.moveDown(0.5);

    const arabicLine = prepareArabicForPdfLine(ctx.descriptionAr);
    if (fs.existsSync(fontPath)) {
      doc.font("NotoAr").fontSize(12).fillColor("#1a1a1a");
    } else {
      doc.font("Helvetica").fontSize(11).fillColor("#1a1a1a");
    }
    doc.text(arabicLine, margin, doc.y, {
      width: contentW,
      align: "right",
    });

    doc.moveDown(1);
    doc.font("Helvetica").fontSize(10).fillColor("#555555");
    doc.text(`Area: ${ctx.area}`, margin, doc.y, { width: contentW });

    doc.moveDown(1.2);
    doc.font("Helvetica").fontSize(10).fillColor("#555555");
    doc.text(
      `Amount: ${ctx.amount.toFixed(3)} KWD`,
      margin,
      doc.y,
      { width: contentW }
    );

    doc.moveDown(2);
    doc.moveTo(margin, doc.y).lineTo(pageW - margin, doc.y).strokeColor("#E8ECF1").lineWidth(1).stroke();
    doc.moveDown(0.8);

    doc.fillColor(NAVY).font("Helvetica-Bold").fontSize(12);
    doc.text(`Total: ${ctx.amount.toFixed(3)} KWD`, margin, doc.y, {
      width: contentW,
    });
    doc.moveDown(0.45);
    doc.font("Helvetica-Bold").fontSize(10).text(
      `Status: ${statusLine}`,
      margin,
      doc.y,
      {
        width: contentW,
      }
    );

    const footerY = doc.page.height - margin - 24;
    doc.font("Helvetica").fontSize(9).fillColor("#8899AA");
    doc.text(FOOTER_THANKS, margin, footerY, {
      width: contentW,
      align: "center",
    });

    doc.end();
  });
}
