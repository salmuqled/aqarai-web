/**
 * Backfill `properties.priceType` when missing or invalid.
 * Inference MUST match:
 *   - functions/src/agent_brain.ts (`inferPriceTypeMissingFromListingType`)
 *   - lib/utils/property_price_type.dart (`PropertyPriceType.inferMissingFromListingType`)
 *
 * Usage:
 *   node scripts/backfill_price_type.mjs --dry-run
 *   node scripts/backfill_price_type.mjs --commit
 *
 * Env: FIREBASE_PROJECT_ID or .firebaserc default (same pattern as propertyStatusCleanup.mjs).
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import admin from "firebase-admin";

const __dirname = dirname(fileURLToPath(import.meta.url));

const VALID = new Set(["daily", "monthly", "yearly", "full"]);

const LEGACY_MONTHLY_TYPES = new Set([
  "apartment",
  "house",
  "villa",
  "office",
  "shop",
  "building",
]);

function inferPriceTypeMissingFromListingType(propertyType) {
  const p = String(propertyType ?? "")
    .trim()
    .toLowerCase();
  if (p === "chalet") return "daily";
  if (LEGACY_MONTHLY_TYPES.has(p)) return "monthly";
  return "full";
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

  let scanned = 0;
  let updated = 0;
  let wouldUpdate = 0;
  let skipped = 0;

  let lastDoc = null;
  const batchSize = 400;

  // eslint-disable-next-line no-constant-condition
  while (true) {
    let q = db.collection("properties").orderBy(admin.firestore.FieldPath.documentId()).limit(batchSize);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      scanned++;
      const data = doc.data() ?? {};
      const raw = data.priceType;
      const stored = typeof raw === "string" ? raw.trim().toLowerCase() : "";
      if (VALID.has(stored)) {
        skipped++;
        continue;
      }
      const listingType = String(data.type ?? "");
      const inferred = inferPriceTypeMissingFromListingType(listingType);
      const oldState = stored === "" ? "(missing)" : `(invalid:${String(raw).slice(0, 40)})`;
      console.log(
        JSON.stringify({
          propertyId: doc.id,
          oldPriceType: raw ?? null,
          oldState,
          newPriceType: inferred,
          mode: commit ? "UPDATE" : "DRY_RUN",
        }),
      );
      if (commit) {
        await doc.ref.update({
          priceType: inferred,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        updated++;
      } else {
        wouldUpdate++;
      }
    }
    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < batchSize) break;
  }

  if (!commit) {
    console.log(
      JSON.stringify({
        summary: "dry-run (no writes)",
        totalScanned: scanned,
        totalWouldUpdate: wouldUpdate,
        totalSkippedValid: skipped,
      }),
    );
    console.log("Re-run with --commit to apply updates.");
  } else {
    console.log(
      JSON.stringify({
        summary: "commit complete",
        totalScanned: scanned,
        totalUpdated: updated,
        totalSkippedValid: skipped,
      }),
    );
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
