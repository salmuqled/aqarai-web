/**
 * Builds invoice fields purely from Firestore + Auth (no manual invoice input).
 */
import * as admin from "firebase-admin";

import { areaDisplayEnglish } from "./invoicePdfAreaEn";

export type InvoiceServiceType =
  | "rent"
  | "sale"
  | "chalet"
  | "property_feature";

export interface PaymentInvoiceContext {
  companyId: string;
  companyName: string;
  companyEmail: string | null;
  /**
   * Auth UID of the user this invoice belongs to (the payer / addressee).
   * Used by Firestore rules so the user can READ their own invoice. `null`
   * for fully manual / unlinked rows where no end-user identity exists.
   */
  clientId: string | null;
  serviceType: InvoiceServiceType;
  area: string;
  descriptionAr: string;
  amount: number;
  /** English invoice line item (empty when unknown). */
  propertyType: string;
  block: string;
  street: string;
  /** Formatted e.g. "12,345.000 KWD", or "". */
  propertyPrice: string;
  /**
   * When set, overrides the default English title from [serviceType] in the PDF
   * (e.g. `Property Featuring - 7 days`).
   */
  lineItemTitleOverrideEn?: string;
  /**
   * When set, replaces the standard Area/Type/Block HTML block (featured ads).
   */
  lineItemDetailsOverrideHtml?: string;
}

function str(v: unknown): string {
  if (v == null) return "";
  return String(v).trim();
}

function num(v: unknown): number {
  if (typeof v === "number" && !Number.isNaN(v)) return v;
  if (typeof v === "string") {
    const x = parseFloat(v);
    return Number.isNaN(x) ? 0 : x;
  }
  return 0;
}

function isChaletListing(
  propertyType: string,
  listingCategory: string
): boolean {
  const pt = propertyType.toLowerCase();
  const lc = listingCategory.toLowerCase();
  return pt === "chalet" || lc === "chalet";
}

function descriptionAr(serviceType: InvoiceServiceType, area: string): string {
  const a = area.trim() || "الكويت";
  const map: Record<InvoiceServiceType, string> = {
    rent: `عمولة تأجير عقار – ${a}`,
    sale: `عمولة بيع عقار – ${a}`,
    chalet: `عمولة حجز شاليه – ${a}`,
    property_feature: `تمييز إعلان — ${a}`,
  };
  return map[serviceType];
}

function serviceTypeFromReason(reason: string): InvoiceServiceType {
  if (reason === "rent") return "rent";
  if (reason === "sale") return "sale";
  return "sale";
}

function formatKwdDisplay(amount: number): string {
  const n = Number.isFinite(amount) ? amount : 0;
  if (n <= 0) return "";
  const parts = n.toLocaleString("en-US", {
    minimumFractionDigits: 3,
    maximumFractionDigits: 3,
  });
  return `${parts} KWD`;
}

const emptyPropertyLines = (): Pick<
  PaymentInvoiceContext,
  "propertyType" | "block" | "street" | "propertyPrice"
> => ({
  propertyType: "",
  block: "",
  street: "",
  propertyPrice: "",
});

async function propertyDetailsFromDeal(
  db: admin.firestore.Firestore,
  d: Record<string, unknown>
): Promise<Pick<
  PaymentInvoiceContext,
  "propertyType" | "block" | "street" | "propertyPrice"
>> {
  let propertyType = str(d.propertyType);
  let block = str(d.block ?? d.blockAr ?? d.blockEn);
  let street = str(d.street ?? d.streetAr ?? d.streetEn);
  let priceNum =
    num(d.finalPrice) || num(d.listingPrice) || num(d.price);

  const propertyId = str(d.propertyId);
  if (propertyId) {
    try {
      const pSnap = await db.collection("properties").doc(propertyId).get();
      const p = pSnap.data();
      if (p) {
        if (!propertyType) propertyType = str(p.type);
        if (!block) block = str(p.block ?? p.blockAr ?? p.blockEn);
        if (!street) {
          street = str(
            p.street ?? p.streetAr ?? p.streetEn ?? p.address ?? p.addressLine
          );
        }
        if (!priceNum) priceNum = num(p.price);
      }
    } catch {
      /* ignore */
    }
  }

  return {
    propertyType,
    block,
    street,
    propertyPrice: priceNum > 0 ? formatKwdDisplay(priceNum) : "",
  };
}

async function loadClientProfile(uid: string): Promise<{
  name: string;
  email: string | null;
}> {
  const db = admin.firestore();
  let docName = "";
  try {
    const snap = await db.collection("users").doc(uid).get();
    const d = snap.data();
    if (d) {
      docName = str(d.fullName || d.displayName || d.name || d.userName);
    }
  } catch {
    // ignore
  }
  try {
    const u = await admin.auth().getUser(uid);
    const name =
      str(u.displayName) ||
      docName ||
      (u.email ? u.email.split("@")[0] : "") ||
      "Client";
    const email = u.email && u.email.includes("@") ? u.email : null;
    return { name, email };
  } catch {
    return {
      name: docName || "Client",
      email: null,
    };
  }
}

export async function resolvePaymentInvoiceContext(
  paymentId: string,
  payment: Record<string, unknown>
): Promise<PaymentInvoiceContext | null> {
  const amount = num(payment.amount);
  if (amount <= 0) return null;

  const relatedType = str(payment.relatedType);
  const relatedId = str(payment.relatedId);
  const reason = str(payment.reason) || "other";

  const db = admin.firestore();

  if (relatedType === "deal" && relatedId) {
    const dealSnap = await db.collection("deals").doc(relatedId).get();
    if (!dealSnap.exists) return null;
    const d = dealSnap.data()!;
    const ownerId = str(d.ownerId);
    if (!ownerId) return null;

    const area =
      str(d.areaAr) || str(d.areaEn) || str(d.governorateAr) || "الكويت";
    const propertyType = str(d.propertyType);
    const listingCategory = str(d.listingCategory);
    const dealType = str(d.dealType);

    let serviceType: InvoiceServiceType;
    if (isChaletListing(propertyType, listingCategory)) {
      serviceType = "chalet";
    } else if (dealType === "rent") {
      serviceType = "rent";
    } else {
      serviceType = "sale";
    }

    const profile = await loadClientProfile(ownerId);
    const propLines = await propertyDetailsFromDeal(db, d);
    return {
      companyId: ownerId,
      companyName: profile.name,
      companyEmail: profile.email,
      clientId: ownerId,
      serviceType,
      area,
      descriptionAr: descriptionAr(serviceType, area),
      amount,
      ...propLines,
    };
  }

  if (relatedType === "auction_request" && relatedId) {
    const reqSnap = await db.collection("auction_requests").doc(relatedId).get();
    if (!reqSnap.exists) return null;
    const r = reqSnap.data()!;
    const userId = str(r.userId);
    if (!userId) return null;

    const area =
      str(r.areaAr) || str(r.area) || str(r.areaEn) || str(r.governorateAr) || "الكويت";
    const propertyType = str(r.propertyType);
    const serviceType: InvoiceServiceType = propertyType.toLowerCase() === "chalet"
      ? "chalet"
      : "sale";

    const profile = await loadClientProfile(userId);
    const priceVal = num(r.price);
    return {
      companyId: userId,
      companyName: profile.name,
      companyEmail: profile.email,
      clientId: userId,
      serviceType,
      area,
      descriptionAr: descriptionAr(serviceType, area),
      amount,
      propertyType: str(r.propertyType),
      block: "",
      street: "",
      propertyPrice: priceVal > 0 ? formatKwdDisplay(priceVal) : "",
    };
  }

  // Manual / unlinked ledger row: still invoice with best-effort metadata.
  const createdBy = str(payment.createdBy);
  const fallbackUid = createdBy || "unknown";
  const st = serviceTypeFromReason(reason);
  const area = "الكويت";
  let companyName = "Manual payment";
  let companyEmail: string | null = null;
  if (createdBy) {
    const p = await loadClientProfile(createdBy);
    companyName = p.name;
    companyEmail = p.email;
  }
  return {
    companyId: `manual_${fallbackUid}`,
    companyName,
    companyEmail,
    // Manual rows are admin-only — no end-user "owner" of the invoice.
    clientId: createdBy || null,
    serviceType: st,
    area,
    descriptionAr: descriptionAr(st, area),
    amount,
    ...emptyPropertyLines(),
  };
}

function escapeHtmlInvoice(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Invoice context for paid «feature my listing» (MyFatoorah → featurePropertyPaid).
 * PDF line item matches product copy: `Property Featuring - [N] days`.
 */
export async function buildFeaturedPropertyInvoiceContext(params: {
  uid: string;
  propertyId: string;
  durationDays: number;
  amountKwd: number;
  newFeaturedUntil: Date;
}): Promise<PaymentInvoiceContext | null> {
  const db = admin.firestore();
  const profile = await loadClientProfile(params.uid);
  const propSnap = await db.collection("properties").doc(params.propertyId).get();
  if (!propSnap.exists) return null;
  const p = propSnap.data() as Record<string, unknown>;
  const area = str(p.areaAr ?? p.area) || "الكويت";
  const propertyType = str(p.type);
  const lineTitle = `Property Featuring - ${params.durationDays} days`;
  const untilStr = params.newFeaturedUntil.toLocaleString("en-GB", {
    timeZone: "Asia/Kuwait",
    dateStyle: "medium",
    timeStyle: "short",
  });
  const areaEn = areaDisplayEnglish(area);
  const detailsLines = [
    `Property ID — ${params.propertyId}`,
    `Plan — ${params.durationDays} days`,
    `Featured until — ${untilStr}`,
    `Area — ${areaEn}`,
    `Property type — ${propertyType || "—"}`,
  ];
  const lineItemDetailsOverrideHtml = detailsLines
    .map((line) => `<div class="sub">${escapeHtmlInvoice(line)}</div>`)
    .join("");

  return {
    companyId: params.uid,
    companyName: profile.name || "Valued Customer",
    companyEmail: profile.email,
    clientId: params.uid,
    serviceType: "property_feature",
    area,
    descriptionAr: `تمييز إعلان — ${params.durationDays} يوم — ${area}`,
    amount: params.amountKwd,
    propertyType,
    block: "",
    street: "",
    propertyPrice: "",
    lineItemTitleOverrideEn: lineTitle,
    lineItemDetailsOverrideHtml,
  };
}
