/**
 * Dual-approval review window after a lot enters `pending_admin_review`.
 * Override hours with env `AUCTION_APPROVAL_TIMEOUT_HOURS` on the function (default 24).
 */
const parsed = Number(process.env.AUCTION_APPROVAL_TIMEOUT_HOURS ?? "24");
const hours = Number.isFinite(parsed) && parsed > 0 ? parsed : 24;

/** Duration from entering `pending_admin_review` until auto-reject if not fully approved. */
export const AUCTION_APPROVAL_TIMEOUT_MS = hours * 60 * 60 * 1000;
