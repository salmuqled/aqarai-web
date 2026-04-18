/**
 * Creates seed docs to materialize Firestore collections:
 * - bookings
 * - blocked_dates
 *
 * This does not touch existing collections.
 *
 * Usage:
 *   export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
 *   node tools/seed_booking_collections.js --project aqarai-caf5d
 */
/* eslint-disable no-console */

function parseArgs(argv) {
  const out = { project: "" };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = argv[i + 1];
    if (a === "--project" && next) {
      out.project = next;
      i++;
    }
  }
  if (!out.project) throw new Error("Missing --project <firebase-project-id>");
  return out;
}

async function main() {
  const cfg = parseArgs(process.argv);

  const admin = require("firebase-admin");
  if (admin.apps.length === 0) {
    admin.initializeApp({ projectId: cfg.project });
  }
  const db = admin.firestore();
  const { FieldValue, Timestamp } = admin.firestore;

  const now = Timestamp.now();
  const tomorrow = Timestamp.fromMillis(now.toMillis() + 24 * 60 * 60 * 1000);

  const bookingSeedRef = db.collection("bookings").doc("_seed_structure");
  const blockedSeedRef = db.collection("blocked_dates").doc("_seed_structure");

  // Minimal seed docs: intentionally use placeholder ids.
  // These can be deleted safely later.
  const bookingSeed = {
    propertyId: "properties/<propertyId>",
    userId: "<uid>",
    startDate: now,
    endDate: tomorrow,
    totalDays: 1,
    pricePerNight: 0,
    totalPrice: 0,
    status: "pending", // confirmed / pending / cancelled
    source: "app",
    commissionApplied: true,
    createdAt: FieldValue.serverTimestamp(),
  };

  const blockedSeed = {
    propertyId: "properties/<propertyId>",
    startDate: now,
    endDate: tomorrow,
    source: "external",
    commissionApplied: false,
    note: "seed doc (safe to delete)",
    createdAt: FieldValue.serverTimestamp(),
  };

  await bookingSeedRef.set(bookingSeed, { merge: false });
  await blockedSeedRef.set(blockedSeed, { merge: false });

  console.log("Seed docs created:");
  console.log(`- bookings/_seed_structure`);
  console.log(`- blocked_dates/_seed_structure`);
  console.log(`Project: ${cfg.project}`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

