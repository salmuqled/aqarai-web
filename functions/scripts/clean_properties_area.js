/**
 * One-time Firestore cleanup: fix broken `areaAr` / `area` on `properties`.
 *
 * Prerequisite (mapping must be compiled):
 *   cd functions && npm run build
 *
 * Service account:
 *   Firebase Console → Project settings → Service accounts → Generate new private key
 *   Save as JSON (e.g. functions/serviceAccountKey.json) — do NOT commit it.
 *
 * Run from the `functions` directory:
 *   node scripts/clean_properties_area.js serviceAccountKey.json
 *
 * Or with an absolute path to the key:
 *   node scripts/clean_properties_area.js /path/to/serviceAccountKey.json
 *
 * Rules:
 *   - Only updates `areaAr` and/or `area` when those fields are invalid.
 *   - Never deletes documents; never touches unrelated fields.
 *   - Batches writes (max 500 Firestore batch operations per commit).
 */
"use strict";

const path = require("path");
const admin = require("firebase-admin");

let areaArToEn;
let propertyLocationCode;
try {
  ({ areaArToEn, propertyLocationCode } = require("../lib/invoice/invoicePdfAreaEn"));
} catch (e) {
  console.error(
    "Failed to load ../lib/invoice/invoicePdfAreaEn.js — run `npm run build` inside `functions` first.",
  );
  console.error(e.message);
  process.exit(1);
}

const keyPath = process.argv[2];
if (!keyPath) {
  console.error(
    "Usage: node scripts/clean_properties_area.js <path-to-serviceAccountKey.json>",
  );
  console.error(
    "Example: node scripts/clean_properties_area.js serviceAccountKey.json",
  );
  process.exit(1);
}

const keyFullPath = path.isAbsolute(keyPath)
  ? keyPath
  : path.join(__dirname, "..", keyPath);

let serviceAccount;
try {
  serviceAccount = require(keyFullPath);
} catch (e) {
  console.error("Failed to load key file:", keyFullPath, e.message);
  process.exit(1);
}

if (!admin.apps.length) {
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
}

const db = admin.firestore();

/** @type {Record<string, string>} */
const AREA_CODE_TO_AR = (() => {
  const m = {};
  for (const [ar, en] of Object.entries(areaArToEn)) {
    const code = propertyLocationCode(en && en.length > 0 ? en : ar);
    if (!code) continue;
    if (m[code] === undefined) m[code] = ar;
  }
  return m;
})();

/**
 * Invalid placeholder values for area-related *stored* fields we may read or fix.
 */
function isInvalidAreaValue(v) {
  if (v === undefined || v === null) return true;
  const s = String(v).trim();
  if (s.length === 0) return true;
  if (s === "-" || s === "\u2014" || s === "\u2013" || s === "\u2212") return true;
  const lower = s.toLowerCase();
  if (lower === "n/a" || lower === "null") return true;
  return false;
}

function isValidAreaValue(v) {
  return !isInvalidAreaValue(v);
}

function englishLabelToArabic(enRaw) {
  const t = String(enRaw).trim().toLowerCase();
  if (!t) return null;
  for (const [ar, en] of Object.entries(areaArToEn)) {
    if (String(en).trim().toLowerCase() === t) return ar;
  }
  return null;
}

function arabicFromCodeRaw(codeRaw) {
  const trimmed = String(codeRaw).trim();
  if (!trimmed) return null;
  const normalized = propertyLocationCode(trimmed);
  if (!normalized) return null;
  return AREA_CODE_TO_AR[normalized] || null;
}

/**
 * Resolve Arabic label using priority:
 * 1. areaAr (if valid)
 * 2. area (if valid)
 * 3. areaEn → mapping / slug
 * 4. areaCode / area_id
 */
function resolveArabicCandidate(data) {
  if (isValidAreaValue(data.areaAr)) {
    return String(data.areaAr).trim();
  }
  if (isValidAreaValue(data.area)) {
    return String(data.area).trim();
  }

  if (isValidAreaValue(data.areaEn)) {
    const enStr = String(data.areaEn).trim();
    const fromEn = englishLabelToArabic(enStr);
    if (fromEn) return fromEn;
    const fromSlug = arabicFromCodeRaw(enStr);
    if (fromSlug) return fromSlug;
  }

  const codeRaw =
    data.areaCode != null && String(data.areaCode).trim() !== ""
      ? String(data.areaCode).trim()
      : data.area_id != null && String(data.area_id).trim() !== ""
        ? String(data.area_id).trim()
        : "";

  if (codeRaw) {
    const fromCode = arabicFromCodeRaw(codeRaw);
    if (fromCode) return fromCode;
  }

  return null;
}

const BATCH_SIZE = 500;

async function main() {
  let totalScanned = 0;
  let totalFixed = 0;
  let totalSkipped = 0;
  let totalUnresolved = 0;

  let lastDoc = null;
  // Stable pagination (avoid loading entire collection into RAM).
  while (true) {
    let q = db.collection("properties").orderBy(admin.firestore.FieldPath.documentId()).limit(300);
    if (lastDoc) q = q.startAfter(lastDoc);
    const snap = await q.get();
    if (snap.empty) break;

    /** @type {FirebaseFirestore.WriteBatch | null} */
    let batch = db.batch();
    let batchOps = 0;

    const commitBatch = async () => {
      if (batchOps === 0) return;
      await batch.commit();
      batch = db.batch();
      batchOps = 0;
    };

    for (const doc of snap.docs) {
      totalScanned += 1;
      const data = doc.data() || {};

      const needAreaAr = isInvalidAreaValue(data.areaAr);
      const needArea = isInvalidAreaValue(data.area);

      if (!needAreaAr && !needArea) {
        totalSkipped += 1;
        continue;
      }

      const candidate = resolveArabicCandidate(data);
      if (!candidate) {
        totalUnresolved += 1;
        console.log(
          `[unresolved] ${doc.id} areaAr=${JSON.stringify(data.areaAr)} area=${JSON.stringify(data.area)} areaEn=${JSON.stringify(data.areaEn)} areaCode=${JSON.stringify(data.areaCode)}`,
        );
        continue;
      }

      /** @type {Record<string, string>} */
      const patch = {};
      if (needAreaAr) patch.areaAr = candidate;
      if (needArea) patch.area = candidate;

      if (Object.keys(patch).length === 0) {
        totalSkipped += 1;
        continue;
      }

      batch.update(doc.ref, patch);
      batchOps += 1;
      totalFixed += 1;

      if (batchOps >= BATCH_SIZE) {
        await commitBatch();
      }
    }

    await commitBatch();
    lastDoc = snap.docs[snap.docs.length - 1];
  }

  console.log("---");
  console.log("total scanned:   ", totalScanned);
  console.log("total fixed:     ", totalFixed, "(documents updated)");
  console.log("total skipped:   ", totalSkipped, "(areaAr & area already valid)");
  console.log("total unresolved:", totalUnresolved, "(could not infer Arabic area)");
  console.log("Done.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
