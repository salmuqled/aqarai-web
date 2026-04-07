/**
 * One-time backfill: create `transactions/{bookingId}` for confirmed chalet bookings missing a ledger row.
 *
 * Skips when:
 *   - `transactions/{bookingId}` already exists (canonical id), OR
 *   - any legacy doc exists with field `bookingId` == booking (avoids duplicate if old `.add()` rows exist).
 *
 * Prerequisite:
 *   cd functions && npm run build
 *
 * Run:
 *   node scripts/backfill_chalet_booking_transactions.js path/to/serviceAccountKey.json
 *
 * Do NOT commit service account keys.
 */
"use strict";

const path = require("path");
const admin = require("firebase-admin");

const keyPath = process.argv[2];
if (!keyPath) {
  console.error("Usage: node scripts/backfill_chalet_booking_transactions.js <serviceAccountKey.json>");
  process.exit(1);
}

let createTransactionFromConfirmedBooking;
try {
  ({ createTransactionFromConfirmedBooking } = require("../lib/chalet_booking_finance"));
} catch (e) {
  console.error("Run `npm run build` in functions/ first.", e.message);
  process.exit(1);
}

const resolvedKey = path.resolve(process.cwd(), keyPath);
const serviceAccount = require(resolvedKey);

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

async function alreadyHasLedger(bookingId) {
  const byId = await db.collection("transactions").doc(bookingId).get();
  if (byId.exists) return true;
  const legacy = await db
    .collection("transactions")
    .where("bookingId", "==", bookingId)
    .limit(1)
    .get();
  return !legacy.empty;
}

async function main() {
  let processed = 0;
  let created = 0;
  let skipped = 0;
  const failures = [];

  let lastDoc = null;
  const pageSize = 200;

  for (;;) {
    let q = db.collection("bookings").where("status", "==", "confirmed").limit(pageSize);
    if (lastDoc) {
      q = q.startAfter(lastDoc);
    }
    const snap = await q.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      processed++;
      const bookingId = doc.id;
      try {
        if (await alreadyHasLedger(bookingId)) {
          skipped++;
          continue;
        }
        await createTransactionFromConfirmedBooking(bookingId);
        const check = await db.collection("transactions").doc(bookingId).get();
        if (check.exists) created++;
        else skipped++;
      } catch (err) {
        failures.push({ bookingId, error: err.message || String(err) });
      }
    }

    lastDoc = snap.docs[snap.docs.length - 1];
    if (snap.size < pageSize) break;
  }

  console.log(
    JSON.stringify(
      {
        event: "chalet_transaction_backfill_done",
        processed,
        created,
        skipped,
        failuresCount: failures.length,
        failures: failures.slice(0, 50),
      },
      null,
      2,
    ),
  );
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
