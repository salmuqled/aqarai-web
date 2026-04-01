/**
 * Builds invoice fields purely from Firestore + Auth (no manual invoice input).
 */
import * as admin from "firebase-admin";

export type InvoiceServiceType = "rent" | "sale" | "chalet";

export interface PaymentInvoiceContext {
  companyId: string;
  companyName: string;
  companyEmail: string | null;
  serviceType: InvoiceServiceType;
  area: string;
  descriptionAr: string;
  amount: number;
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
  };
  return map[serviceType];
}

function serviceTypeFromReason(reason: string): InvoiceServiceType {
  if (reason === "rent") return "rent";
  if (reason === "sale") return "sale";
  return "sale";
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
    return {
      companyId: ownerId,
      companyName: profile.name,
      companyEmail: profile.email,
      serviceType,
      area,
      descriptionAr: descriptionAr(serviceType, area),
      amount,
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
    return {
      companyId: userId,
      companyName: profile.name,
      companyEmail: profile.email,
      serviceType,
      area,
      descriptionAr: descriptionAr(serviceType, area),
      amount,
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
    serviceType: st,
    area,
    descriptionAr: descriptionAr(st, area),
    amount,
  };
}
