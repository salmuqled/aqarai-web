/**
 * One-time admin maintenance: normalize `properties.areaCode` to canonical codes.
 *
 * Safety:
 * - Dry-run by default (no writes)
 * - When committing, updates ONLY `areaCode` (+ `updatedAt` optionally disabled)
 * - Writes an append-only JSONL log locally for reversibility (docId + before/after)
 *
 * Auth:
 * - Uses Application Default Credentials:
 *   - export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
 *   - OR run in an environment with ADC (e.g. gcloud auth application-default login)
 *
 * Usage:
 *   node tools/normalize_area_code.js --project aqarai-caf5d --dry-run
 *   node tools/normalize_area_code.js --project aqarai-caf5d --commit
 */
/* eslint-disable no-console */

const fs = require("node:fs");
const path = require("node:path");

function parseArgs(argv) {
  const out = {
    project: "",
    commit: false,
    dryRun: true,
    pageSize: 400,
    maxDocs: 0, // 0 == unlimited
    logPath: "",
    updateUpdatedAt: false,
    sample: 20,
  };

  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = argv[i + 1];
    if (a === "--project" && next) {
      out.project = next;
      i++;
    } else if (a === "--commit") {
      out.commit = true;
      out.dryRun = false;
    } else if (a === "--dry-run") {
      out.commit = false;
      out.dryRun = true;
    } else if (a === "--page-size" && next) {
      out.pageSize = Math.max(1, Math.min(1000, Number(next) || out.pageSize));
      i++;
    } else if (a === "--max-docs" && next) {
      out.maxDocs = Math.max(0, Number(next) || 0);
      i++;
    } else if (a === "--log" && next) {
      out.logPath = next;
      i++;
    } else if (a === "--update-updatedAt") {
      out.updateUpdatedAt = true;
    } else if (a === "--sample" && next) {
      out.sample = Math.max(0, Number(next) || out.sample);
      i++;
    }
  }

  if (!out.project) {
    throw new Error("Missing --project <firebase-project-id>");
  }

  if (!out.logPath) {
    const ts = new Date().toISOString().replace(/[:.]/g, "-");
    out.logPath = path.join(
      process.cwd(),
      "tools",
      `areaCode-normalization-${out.project}-${ts}.jsonl`,
    );
  }

  return out;
}

// ---------------------------------------------------------------------------
// Canonical area registry (must match Flutter's unified registry).
// NOTE: Keep in sync with `lib/data/kuwait_areas.dart` (AreaModel list).
// ---------------------------------------------------------------------------
const AREAS = [
  { code: "salmiya", ar: "السالمية", en: "Salmiya" },
  { code: "hawally", ar: "حولي", en: "Hawally" },
  { code: "jabriya", ar: "الجابرية", en: "Jabriya" },
  { code: "khaitan", ar: "خيطان", en: "Khaitan" },
  { code: "farwaniya", ar: "الفروانية", en: "Farwaniya" },
  { code: "mahboula", ar: "المهبولة", en: "Mahboula" },
  { code: "fahaheel", ar: "الفحيحيل", en: "Fahaheel" },
  // Chalet areas
  { code: "khiran", ar: "الخيران", en: "Khiran" },
  { code: "bneider", ar: "بنيدر", en: "Bneider" },
  { code: "zour", ar: "الزور", en: "Zour" },
  { code: "nuwaiseeb", ar: "النويصيب", en: "Nuwaiseeb" },
  { code: "julaia", ar: "الجليعة", en: "Julaia" },
  { code: "dhubaiya", ar: "الضباعية", en: "Dhubaiya" },
];

function collapseSpaces(s) {
  return String(s || "")
    .trim()
    .replace(/\s+/g, " ");
}

function normalizeLatin(s) {
  return collapseSpaces(s).toLowerCase();
}

function scoreNameMatch(name, query) {
  if (!name || !query) return 0;
  if (name === query) return 100;
  if (name.startsWith(query)) return 85;
  if (name.includes(query)) return 60;
  return 0;
}

function propertyLocationCode(s) {
  let v = String(s || "").trim().toLowerCase();
  v = v.replace(/\s+/g, "_");
  v = v.replace(/-/g, "_");
  v = v.replace(/[^a-z0-9_]+/g, "");
  v = v.replace(/_+/g, "_");
  v = v.replace(/^_+|_+$/g, "");
  return v;
}

function resolveAreaCodeFromText(input) {
  const collapsed = collapseSpaces(input);
  if (!collapsed) return null;
  const latin = collapsed.toLowerCase();

  let bestScore = 0;
  let bestCode = null;

  for (const a of AREAS) {
    const ar = collapseSpaces(a.ar);
    const en = normalizeLatin(a.en);
    const scoreAr = scoreNameMatch(ar, collapsed);
    const scoreEn = scoreNameMatch(en, latin);
    const score = scoreAr > scoreEn ? scoreAr : scoreEn;
    if (score > bestScore) {
      bestScore = score;
      bestCode = a.code;
    }
  }

  return bestScore > 0 ? bestCode : null;
}

function getUnifiedAreaCode(input, fallbackSlugSource) {
  const collapsed = collapseSpaces(input);
  const resolved = collapsed ? resolveAreaCodeFromText(collapsed) : null;
  if (resolved) return resolved;

  const fb =
    fallbackSlugSource && String(fallbackSlugSource).trim()
      ? String(fallbackSlugSource)
      : collapsed;
  return propertyLocationCode(fb);
}

function pickBestAreaInput(areaAr, areaEn) {
  const ar = String(areaAr || "").trim();
  const en = String(areaEn || "").trim();
  // Prefer Arabic label if present (matches Flutter `_resolvedAreaCode` rawInput).
  return ar || en || "";
}

async function main() {
  const cfg = parseArgs(process.argv);

  const admin = require("firebase-admin");
  if (admin.apps.length === 0) {
    admin.initializeApp({ projectId: cfg.project });
  }
  const db = admin.firestore();

  fs.mkdirSync(path.dirname(cfg.logPath), { recursive: true });
  const logStream = fs.createWriteStream(cfg.logPath, { flags: "a" });

  // Quick sanity: total docs in collection (server-side aggregation).
  try {
    const totalSnap = await db.collection("properties").count().get();
    console.log(`Total properties (count): ${totalSnap.data().count ?? "?"}`);
  } catch (e) {
    console.log(`Total properties (count): unavailable (${e?.message || e})`);
  }

  console.log(
    JSON.stringify(
      {
        project: cfg.project,
        mode: cfg.dryRun ? "dry-run" : "commit",
        pageSize: cfg.pageSize,
        maxDocs: cfg.maxDocs,
        updateUpdatedAt: cfg.updateUpdatedAt,
        logPath: cfg.logPath,
      },
      null,
      2,
    ),
  );

  let scanned = 0;
  let updated = 0;
  let lastDocSnap = null;

  const samples = [];

  while (true) {
    if (cfg.maxDocs > 0 && scanned >= cfg.maxDocs) break;

    let q = db
      .collection("properties")
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(cfg.pageSize);
    if (lastDocSnap) q = q.startAfter(lastDocSnap);

    const snap = await q.get();
    if (snap.empty) break;

    const batch = cfg.commit ? db.batch() : null;
    let batchWrites = 0;

    for (const doc of snap.docs) {
      if (cfg.maxDocs > 0 && scanned >= cfg.maxDocs) break;
      scanned++;

      const d = doc.data() || {};
      const current = String(d.areaCode ?? "").trim();
      const areaAr = d.areaAr ?? "";
      const areaEn = d.areaEn ?? "";

      const rawInput = pickBestAreaInput(areaAr, areaEn);
      const next = getUnifiedAreaCode(
        rawInput,
        String(areaEn || areaAr || ""),
      );

      const shouldUpdate =
        next &&
        next.trim() &&
        next.trim() !== current &&
        // treat empty / placeholder as needing normalization
        (current === "" || true);

      if (shouldUpdate) {
        updated++;

        const rec = {
          ts: new Date().toISOString(),
          docId: doc.id,
          before: { areaCode: current, areaAr: String(areaAr), areaEn: String(areaEn) },
          after: { areaCode: next },
        };
        logStream.write(`${JSON.stringify(rec)}\n`);

        if (samples.length < cfg.sample) {
          samples.push(rec);
        }

        if (cfg.commit) {
          const payload = { areaCode: next };
          if (cfg.updateUpdatedAt) {
            payload.updatedAt = admin.firestore.FieldValue.serverTimestamp();
          }
          batch.update(doc.ref, payload);
          batchWrites++;
        }
      }
    }

    if (cfg.commit && batchWrites > 0) {
      await batch.commit();
    }

    lastDocSnap = snap.docs[snap.docs.length - 1];

    // Soft progress output
    console.log(
      JSON.stringify(
        {
          scanned,
          updated,
          lastDocId: lastDocSnap?.id ?? null,
        },
        null,
        0,
      ),
    );
  }

  logStream.end();

  console.log("\n=== Summary ===");
  console.log(`Scanned: ${scanned}`);
  console.log(`Updated: ${updated}`);
  console.log(`Log: ${cfg.logPath}`);
  console.log("\n=== Samples ===");
  for (const s of samples) {
    console.log(
      `${s.docId} | ${s.before.areaCode || "(empty)"} -> ${s.after.areaCode} | ${s.before.areaAr} / ${s.before.areaEn}`,
    );
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

