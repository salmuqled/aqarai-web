/**
 * Pure helpers for deal commission payment state.
 * Amounts are in KWD (same as app); use epsilon for float comparison.
 */

export const COMMISSION_AMOUNT_EPS = 0.005;

export type CommissionPaymentStatus =
  | "unpaid"
  | "partial"
  | "paid"
  | "overpaid"
  | "not_applicable";

export function toFiniteNumber(v: unknown, fallback = 0): number {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return fallback;
}

/** Canonical commission due on a deal (prefer commissionAmount). */
export function getDealCommissionDue(dealData: Record<string, unknown>): number {
  const ca = toFiniteNumber(dealData.commissionAmount, NaN);
  if (!Number.isNaN(ca) && ca > 0) return ca;
  return Math.max(0, toFiniteNumber(dealData.commission, 0));
}

export function calculateDealPaymentStatus(
  due: number,
  paidTotal: number,
  eps = COMMISSION_AMOUNT_EPS,
): CommissionPaymentStatus {
  if (due <= eps) return "not_applicable";
  if (paidTotal <= eps) return "unpaid";
  if (paidTotal < due - eps) return "partial";
  if (paidTotal <= due + eps) return "paid";
  return "overpaid";
}

export function commissionOverpaidAmount(
  due: number,
  paidTotal: number,
  eps = COMMISSION_AMOUNT_EPS,
): number {
  if (due <= eps) return Math.max(0, paidTotal);
  return Math.max(0, paidTotal - due);
}

/** Legacy mirror for Flutter that still reads isCommissionPaid. */
export function legacyIsCommissionPaid(
  status: CommissionPaymentStatus,
): boolean {
  return status === "paid" || status === "overpaid";
}

export const FINAL_DEAL_STATUSES = new Set<string>(["signed", "closed"]);

export function isFinalizedDealStatus(status: unknown): boolean {
  return typeof status === "string" && FINAL_DEAL_STATUSES.has(status);
}
