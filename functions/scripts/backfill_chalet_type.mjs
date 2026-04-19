/**
 * Normalize `properties.type` to `"chalet"` when `listingCategory == "chalet"`.
 * Writes ONLY `{ type: "chalet" }` — no other fields.
 *
 * Usage:
 *   node scripts/backfill_chalet_type.mjs --dry-run
 *   node scripts/backfill_chalet_type.mjs --commit
 *
 * Env: FIREBASE_PROJECT_ID or .firebaserc default (same as backfill_price_type.mjs).
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import admin from "firebase-admin";

const __dirname = dirname(fileURLToPath(import.meta.url));

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
    console.error("Set FIREBASE_PROJECT_ID or ensure .firebaserc has projects.default");
    process.exit(1);
  }
  admin.initializeApp({ projectId });
  console.log(JSON.stringify({ projectId, message: "firebase-admin initialized" }));
}

function parseMode(argv) {
  if (argv.includes("--commit")) return "commit";
  return "dry-run";
}

async function main() {
  const mode = parseMode(process.argv);
  const commit = mode === "commit";
  initAdmin();
  const db = admin.firestore();

  const snapshot = await db.collection("properties").where("listingCategory", "==", "chalet").get();

  let scanned = 0;
  let updated = 0;
  let wouldUpdate = 0;
  let skipped = 0;

  for (const doc of snapshot.docs) {
    scanned++;
    const data = doc.data() || {};
    const currentType = String(data.type ?? "")
      .trim()
      .toLowerCase();

    if (currentType === "chalet") {
      skipped++;
      continue;
    }

    console.log(
      JSON.stringify({
        propertyId: doc.id,
        oldType: data.type == null || String(data.type).trim() === "" ? "(missing)" : data.type,
        newType: "chalet",
        mode: commit ? "UPDATE" : "DRY_RUN",
      }),
    );

    if (commit) {
      await doc.ref.update({ type: "chalet" });
      updated++;
    } else {
      wouldUpdate++;
    }
  }

  if (!commit) {
    console.log(
      JSON.stringify({
        summary: "dry-run (no writes)",
        totalScanned: scanned,
        totalWouldUpdate: wouldUpdate,
        totalSkippedAlreadyChalet: skipped,
      }),
    );
    console.log("Re-run with --commit to apply updates.");
  } else {
    console.log(
      JSON.stringify({
        summary: "commit complete",
        totalScanned: scanned,
        totalUpdated: updated,
        totalSkippedAlreadyChalet: skipped,
      }),
    );
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
