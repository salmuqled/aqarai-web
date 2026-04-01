/**
 * One-off / admin repair: create missing financial_ledger rows for historical paid invoices.
 * Idempotent; does not modify invoice documents.
 */
import * as admin from "firebase-admin";
import {
  FieldPath,
  Timestamp,
  type Firestore,
  type QueryDocumentSnapshot,
} from "firebase-admin/firestore";
import { onCall, HttpsError } from "firebase-functions/v2/https";

const INVOICES = "invoices";
const LEDGER = "financial_ledger";
const BATCH_SIZE = 100;
/** Default max query batches per invocation (100 × 2000 = 200k invoice docs max). */
const DEFAULT_MAX_BATCHES = 2000;

function assertAdmin(request: { auth?: { token?: Record<string, unknown> } }) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "User must be authenticated");
  }
  if (request.auth.token?.admin !== true) {
    throw new HttpsError("permission-denied", "Admin only");
  }
}

function str(v: unknown): string {
  if (v == null) return "";
  return String(v);
}

function num(v: unknown): number {
  if (typeof v === "number" && !Number.isNaN(v)) return v;
  if (typeof v === "string") {
    const x = parseFloat(v);
    return Number.isNaN(x) ? 0 : x;
  }
  return 0;
}

function isFirestoreTimestamp(v: unknown): v is Timestamp {
  return (
    v != null &&
    typeof (v as Timestamp).toMillis === "function" &&
    typeof (v as Timestamp).seconds === "number"
  );
}

/** Ledger createdAt: paidAt → createdAt → now (last resort, logged). */
function ledgerCreatedAtFromInvoice(data: Record<string, unknown>): Timestamp {
  if (isFirestoreTimestamp(data.paidAt)) {
    return data.paidAt;
  }
  if (isFirestoreTimestamp(data.createdAt)) {
    return data.createdAt;
  }
  console.warn(
    "backfillLedgerForOldInvoices: invoice missing paidAt/createdAt Timestamp, using now()"
  );
  return Timestamp.now();
}

function buildLedgerPayload(
  invoiceId: string,
  data: Record<string, unknown>
): Record<string, unknown> {
  const amount = num(data.amount);
  return {
    id: invoiceId,
    type: "income",
    source: "invoice",
    amount,
    currency: "KWD",
    invoiceId,
    paymentId: str(data.paymentId),
    companyId: str(data.companyId),
    createdAt: ledgerCreatedAtFromInvoice(data),
  };
}

export const backfillLedgerForOldInvoices = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async (request) => {
    assertAdmin(request);

    const dryRun = request.data?.dryRun === true;
    const startAfterDocId =
      typeof request.data?.startAfterDocId === "string"
        ? request.data.startAfterDocId.trim()
        : "";
    let maxBatches = DEFAULT_MAX_BATCHES;
    const rawMax = request.data?.maxBatches;
    if (typeof rawMax === "number" && rawMax > 0 && rawMax <= 10000) {
      maxBatches = Math.floor(rawMax);
    }

    const db = admin.firestore() as Firestore;

    let scanned = 0;
    let created = 0;
    let skipped = 0;
    let batchesRun = 0;

    let cursorDoc: QueryDocumentSnapshot | undefined;
    if (startAfterDocId) {
      const cur = await db.collection(INVOICES).doc(startAfterDocId).get();
      if (cur.exists) {
        cursorDoc = cur as QueryDocumentSnapshot;
      }
    }

    let lastBatchFull = false;
    let lastProcessedDocId: string | null = null;

    while (batchesRun < maxBatches) {
      let q = db
        .collection(INVOICES)
        .orderBy(FieldPath.documentId())
        .limit(BATCH_SIZE);
      if (cursorDoc) {
        q = q.startAfter(cursorDoc);
      }

      const snap = await q.get();
      if (snap.empty) {
        lastBatchFull = false;
        break;
      }

      let batchCreated = 0;
      let batchSkipped = 0;

      for (const invDoc of snap.docs) {
        scanned++;
        const data = invDoc.data() as Record<string, unknown>;
        const st = str(data.status).toLowerCase();

        if (st !== "paid") {
          skipped++;
          batchSkipped++;
          continue;
        }

        const amount = num(data.amount);
        if (amount <= 0) {
          skipped++;
          batchSkipped++;
          continue;
        }

        const ledgerRef = db.collection(LEDGER).doc(invDoc.id);

        if (dryRun) {
          const led = await ledgerRef.get();
          if (led.exists) {
            skipped++;
            batchSkipped++;
          } else {
            created++;
            batchCreated++;
          }
          continue;
        }

        const result = await db.runTransaction(async (tx) => {
          const ledSnap = await tx.get(ledgerRef);
          if (ledSnap.exists) {
            return "skip" as const;
          }
          tx.set(ledgerRef, buildLedgerPayload(invDoc.id, data));
          return "create" as const;
        });

        if (result === "skip") {
          skipped++;
          batchSkipped++;
        } else {
          created++;
          batchCreated++;
        }
      }

      lastProcessedDocId = snap.docs[snap.docs.length - 1]!.id;
      cursorDoc = snap.docs[snap.docs.length - 1] as QueryDocumentSnapshot;
      lastBatchFull = snap.docs.length === BATCH_SIZE;

      batchesRun++;
      console.log(
        `backfillLedgerForOldInvoices batch ${batchesRun}: size=${snap.docs.length} batchCreated=${batchCreated} batchSkipped=${batchSkipped} totals scanned=${scanned} created=${created} skipped=${skipped} dryRun=${dryRun}`
      );

      if (snap.docs.length < BATCH_SIZE) {
        break;
      }
    }

    const complete = !lastBatchFull;
    const nextStartAfterDocId =
      !complete && lastProcessedDocId ? lastProcessedDocId : null;

    console.log(
      `backfillLedgerForOldInvoices done: scanned=${scanned} created=${created} skipped=${skipped} dryRun=${dryRun} complete=${complete} nextStartAfterDocId=${nextStartAfterDocId ?? "null"}`
    );

    const out: Record<string, unknown> = {
      scanned,
      created,
      skipped,
      dryRun,
      complete,
    };
    if (nextStartAfterDocId) {
      out.nextStartAfterDocId = nextStartAfterDocId;
    }
    return out;
  }
);
