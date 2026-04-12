/**
 * Cleanup: properties with terminal status but deal not closed.
 * Smart restore: pending_approval | pending_upload | active (see CASE rules).
 *
 * Keep logic aligned with: functions/src/propertyListingTerminalGuard.ts
 *
 * Usage:
 *   node scripts/propertyStatusCleanup.mjs [--dry-run]
 *   DRY_RUN=1 node scripts/propertyStatusCleanup.mjs   (legacy)
 *
 * Updates ONLY: status, sold, updatedAt.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import admin from "firebase-admin";

const __dirname = dirname(fileURLToPath(import.meta.url));

const TERMINAL = ["sold", "rented", "exchanged"];

function parseDryRun(argv) {
  if (process.env.DRY_RUN === "1") return true;
  return argv.includes("--dry-run");
}

function resolveProjectId() {
  const fromEnv =
    process.env.FIREBASE_PROJECT_ID ||
    process.env.GOOGLE_CLOUD_PROJECT ||
    process.env.GCLOUD_PROJECT ||
    process.env.GCP_PROJECT;
  if (fromEnv && String(fromEnv).trim()) return String(fromEnv).trim();
  try {
    const firebasercPath = join(__dirname, "..", "..", ".firebaserc");
    const rc = JSON.parse(readFileSync(firebasercPath, "utf8"));
    const def = rc?.projects?.default;
    if (typeof def === "string" && def.trim()) return def.trim();
  } catch {
    // ignore
  }
  return null;
}

function initAdmin() {
  if (admin.apps.length) return;
  const projectId = resolveProjectId();
  if (!projectId) {
    console.error(
      "Could not resolve Firebase project id. Set FIREBASE_PROJECT_ID or keep .firebaserc.",
    );
    process.exit(1);
  }
  admin.initializeApp({ projectId });
  console.log(JSON.stringify({ projectId, message: "firebase-admin initialized" }));
}

/** When deal is not closed, sold is false. When closed, true only for sale. */
function computeSoldForDoc(data) {
  const dealStatus = String(data.dealStatus ?? "").trim();
  if (dealStatus !== "closed") return false;
  const svc = String(data.serviceType ?? "sale").toLowerCase().trim();
  return svc === "sale";
}

/**
 * CASE order (images only — do not use hasImage):
 * 1. No images → pending_upload
 * 2. Else not approved → pending_approval
 * 3. Else approved + images → active
 * 4. Else → active
 */
function correctionForInvalidTerminal(data) {
  const status = String(data.status ?? "").trim();
  const dealStatus = String(data.dealStatus ?? "").trim();
  if (!TERMINAL.includes(status)) return null;
  if (dealStatus === "closed") return null;

  const approved = data.approved === true;
  const imgs = data.images;
  const imagesLen = Array.isArray(imgs) ? imgs.length : 0;
  const hasImages = imagesLen > 0;

  let newStatus;
  let reason;

  if (!hasImages) {
    newStatus = "pending_upload";
    reason = "CASE_1_no_images";
  } else if (!approved) {
    newStatus = "pending_approval";
    reason = "CASE_2_unapproved";
  } else if (approved && hasImages) {
    newStatus = "active";
    reason = "CASE_3_approved_with_images";
  } else {
    newStatus = "active";
    reason = "CASE_4_fallback";
  }

  const newSold = computeSoldForDoc({ ...data, status: newStatus, dealStatus });
  return { newStatus, newSold, reason };
}

async function main() {
  const dryRun = parseDryRun(process.argv);
  initAdmin();
  const db = admin.firestore();

  const snap = await db.collection("properties").where("status", "in", TERMINAL).get();

  let inconsistent = 0;
  let fixed = 0;

  let batch = db.batch();
  let ops = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    const oldStatus = String(data.status ?? "").trim();
    const dealStatus = String(data.dealStatus ?? "").trim();
    const fix = correctionForInvalidTerminal(data);
    if (!fix) continue;

    inconsistent += 1;

    const approved = data.approved === true;
    const imgs = data.images;
    const imagesLen = Array.isArray(imgs) ? imgs.length : 0;

    console.log(
      JSON.stringify({
        propertyId: doc.id,
        oldStatus,
        newStatus: fix.newStatus,
        dealStatus: dealStatus || null,
        approved,
        imagesLen,
        reason: fix.reason,
        newSold: fix.newSold,
        actionTaken: dryRun ? "dry_run" : "updated",
      }),
    );

    if (dryRun) continue;

    batch.update(doc.ref, {
      status: fix.newStatus,
      sold: fix.newSold,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    ops += 1;
    fixed += 1;

    if (ops >= 400) {
      await batch.commit();
      batch = db.batch();
      ops = 0;
    }
  }

  if (!dryRun && ops > 0) {
    await batch.commit();
  }

  console.log(
    JSON.stringify({
      totalDocumentsScanned: snap.size,
      inconsistentFound: inconsistent,
      totalUpdated: dryRun ? 0 : fixed,
      dryRun,
    }),
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
