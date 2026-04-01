/**
 * Production-safe auction schema migration (Firestore).
 *
 * Forward migration:
 * 1) `lots/{lotId}` — normalize to endsAt, currentHighBid, currentHighBidderId, bidCount;
 *    remove legacy endTime, highestBid, highestBidderId when safe (never overwrites existing canonical).
 * 2) `bids/{bidId}` → `lots/{lotId}/bids/{bidId}` — same id; createdAt from timestamp if needed; drop timestamp.
 *
 * Safety:
 * - Max 300 write operations per commit (under Firestore 500 limit).
 * - Retries with exponential backoff + jitter on commits and reads.
 * - Optional backups before mutating (required for non–dry-run forward migration).
 * - Dry run: no writes, logs intended actions + metrics.
 * - Rollback: restores root bids from bid backups, then lot fields from lot backups (reverse of forward).
 *
 * Active bidding:
 * - Lot updates only fill missing canonical fields or remove redundant legacy keys; do not replace
 *   currentHighBid / endsAt if already set by Cloud Functions.
 * - Bid moves are idempotent: if subcollection doc already exists, reconcile and delete root only when safe.
 *
 * Usage:
 *   cd functions && npx ts-node --transpile-only scripts/migrateAuctionSchema.ts [options]
 *
 * Options:
 *   --dry-run              Log only; no writes (including backups).
 *   --rollback             Restore from backups (use after forward migration). Implies --phase=rollback
 *   --phase=lots|bids|all  Forward phases (default: all). Ignored if --rollback.
 *   --skip-backup          DANGEROUS: forward migration without writing backups (not recommended).
 *   --max-ops=300          Max Firestore operations per batch commit (default 300).
 *
 * Examples:
 *   npx ts-node --transpile-only scripts/migrateAuctionSchema.ts --dry-run
 *   npx ts-node --transpile-only scripts/migrateAuctionSchema.ts
 *   npx ts-node --transpile-only scripts/migrateAuctionSchema.ts --phase=lots
 *   npx ts-node --transpile-only scripts/migrateAuctionSchema.ts --rollback --dry-run
 *   npx ts-node --transpile-only scripts/migrateAuctionSchema.ts --rollback
 *
 * Requires: GOOGLE_APPLICATION_CREDENTIALS or `gcloud auth application-default login`.
 * Optional: set GCLOUD_PROJECT / GOOGLE_CLOUD_PROJECT if the Admin SDK cannot infer the project.
 */
import * as admin from "firebase-admin";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const LOT_TRACKED_KEYS = [
  "endTime",
  "endsAt",
  "highestBid",
  "currentHighBid",
  "highestBidderId",
  "currentHighBidderId",
  "bidCount",
] as const;

const BACKUP_VERSION = 1;
const LOT_BACKUP_COLLECTION = "auction_migrate_v1_lot_backups";
const BID_BACKUP_COLLECTION = "auction_migrate_v1_bid_backups";

const DEFAULT_MAX_OPS_PER_BATCH = 300;
const DEFAULT_PAGE_SIZE = 300;
const RETRY_MAX = 8;
const RETRY_BASE_MS = 400;
const RETRY_MAX_MS = 30_000;

function parseArgs(argv: string[]): {
  dryRun: boolean;
  rollback: boolean;
  phase: "lots" | "bids" | "all" | "rollback";
  skipBackup: boolean;
  maxOpsPerBatch: number;
} {
  let dryRun = false;
  let rollback = false;
  let phase: "lots" | "bids" | "all" | "rollback" = "all";
  let skipBackup = false;
  let maxOpsPerBatch = DEFAULT_MAX_OPS_PER_BATCH;

  for (const a of argv) {
    if (a === "--dry-run") dryRun = true;
    else if (a === "--rollback") rollback = true;
    else if (a === "--skip-backup") skipBackup = true;
    else if (a.startsWith("--phase=")) {
      const v = a.slice("--phase=".length).toLowerCase();
      if (v === "lots" || v === "bids" || v === "all") phase = v;
    } else if (a.startsWith("--max-ops=")) {
      const n = parseInt(a.slice("--max-ops=".length), 10);
      if (Number.isFinite(n) && n > 0 && n <= 500) maxOpsPerBatch = n;
    }
  }

  if (rollback) phase = "rollback";

  return { dryRun, rollback, phase, skipBackup, maxOpsPerBatch };
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function jitterMs(base: number): number {
  return Math.floor(base * (0.85 + Math.random() * 0.3));
}

async function withRetry<T>(
  label: string,
  fn: () => Promise<T>,
  options: { maxRetries?: number; baseMs?: number; maxMs?: number } = {}
): Promise<T> {
  const maxRetries = options.maxRetries ?? RETRY_MAX;
  const baseMs = options.baseMs ?? RETRY_BASE_MS;
  const maxMs = options.maxMs ?? RETRY_MAX_MS;
  let lastErr: unknown;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      const msg = e instanceof Error ? e.message : String(e);
      const retryable =
        /deadline|unavailable|aborted|resource-exhausted|timeout|network|ECONNRESET|ETIMEDOUT/i.test(
          msg
        );
      if (attempt === maxRetries || !retryable) {
        console.error(`[retry] ${label} failed after ${attempt + 1} attempt(s): ${msg}`);
        throw e;
      }
      const exp = Math.min(maxMs, baseMs * Math.pow(2, attempt));
      const wait = jitterMs(exp);
      console.warn(`[retry] ${label} attempt ${attempt + 1} → wait ${wait}ms (${msg})`);
      await sleep(wait);
    }
  }
  throw lastErr;
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

interface MigrationMetrics {
  processed: number;
  updated: number;
  skipped: number;
  errors: number;
  errorDetails: string[];
}

function createMetrics(): MigrationMetrics {
  return {
    processed: 0,
    updated: 0,
    skipped: 0,
    errors: 0,
    errorDetails: [],
  };
}

function logMetrics(phase: string, m: MigrationMetrics): void {
  console.log(
    JSON.stringify({
      phase,
      totalProcessed: m.processed,
      totalUpdated: m.updated,
      totalSkipped: m.skipped,
      totalErrors: m.errors,
    })
  );
  if (m.errorDetails.length > 0) {
    console.warn(`[errors] first ${Math.min(20, m.errorDetails.length)} of ${m.errorDetails.length}:`);
    for (const line of m.errorDetails.slice(0, 20)) {
      console.warn(`  - ${line}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Firestore helpers
// ---------------------------------------------------------------------------

{
  const projectId =
    process.env.GCLOUD_PROJECT ||
    process.env.GOOGLE_CLOUD_PROJECT ||
    process.env.GCP_PROJECT;
  if (projectId) {
    admin.initializeApp({ projectId });
  } else {
    admin.initializeApp();
  }
}
const db = admin.firestore();

function ts(v: unknown): admin.firestore.Timestamp | null {
  if (v instanceof admin.firestore.Timestamp) return v;
  return null;
}

function pickLotBackupFields(d: admin.firestore.DocumentData): {
  present: Record<string, unknown>;
  missing: string[];
} {
  const present: Record<string, unknown> = {};
  const missing: string[] = [];
  for (const k of LOT_TRACKED_KEYS) {
    if (d[k] !== undefined) present[k] = d[k];
    else missing.push(k);
  }
  return { present, missing };
}

function buildLotRollbackUpdate(backup: {
  present: Record<string, unknown>;
  missing: string[];
}): Record<string, unknown> {
  const u: Record<string, unknown> = { ...backup.present };
  for (const k of backup.missing) {
    u[k] = admin.firestore.FieldValue.delete();
  }
  return u;
}

// ---------------------------------------------------------------------------
// Batching
// ---------------------------------------------------------------------------

class OpBatch {
  private batch: admin.firestore.WriteBatch;
  private opCount = 0;

  constructor(private readonly db: admin.firestore.Firestore) {
    this.batch = db.batch();
  }

  get size(): number {
    return this.opCount;
  }

  canFit(extra: number, maxOps: number): boolean {
    return this.opCount + extra <= maxOps;
  }

  set(
    ref: admin.firestore.DocumentReference,
    data: admin.firestore.DocumentData,
    options?: admin.firestore.SetOptions
  ): void {
    if (options) this.batch.set(ref, data, options);
    else this.batch.set(ref, data);
    this.opCount++;
  }

  update(
    ref: admin.firestore.DocumentReference,
    data: admin.firestore.UpdateData<admin.firestore.DocumentData>
  ): void {
    this.batch.update(ref, data);
    this.opCount++;
  }

  delete(ref: admin.firestore.DocumentReference): void {
    this.batch.delete(ref);
    this.opCount++;
  }

  async commit(maxOps: number, label: string): Promise<void> {
    if (this.opCount === 0) return;
    if (this.opCount > maxOps) {
      throw new Error(`Batch over limit: ${this.opCount} > ${maxOps}`);
    }
    await withRetry(`${label} commit(${this.opCount} ops)`, () => this.batch.commit());
    this.batch = this.db.batch();
    this.opCount = 0;
  }

  reset(): void {
    this.batch = this.db.batch();
    this.opCount = 0;
  }
}

async function flushIfNeeded(
  b: OpBatch,
  maxOps: number,
  nextOpSize: number,
  label: string
): Promise<void> {
  if (!b.canFit(nextOpSize, maxOps) && b.size > 0) {
    await b.commit(maxOps, label);
  }
}

// ---------------------------------------------------------------------------
// Forward: lots
// ---------------------------------------------------------------------------

interface LotMigrationPlan {
  lotId: string;
  updates: Record<string, unknown>;
  deletes: string[];
  needsBidCountQuery: boolean;
}

function planLotMigration(
  lotId: string,
  d: admin.firestore.DocumentData
): LotMigrationPlan | null {
  const updates: Record<string, unknown> = {};
  const deletes: string[] = [];

  const endLegacy = ts(d.endTime);
  const endCanon = ts(d.endsAt);
  if (!endCanon && endLegacy) {
    updates.endsAt = endLegacy;
    deletes.push("endTime");
  } else if (endCanon && d.endTime !== undefined) {
    deletes.push("endTime");
  }

  if (d.currentHighBid === undefined && d.highestBid !== undefined) {
    updates.currentHighBid = d.highestBid;
    deletes.push("highestBid");
  } else if (d.currentHighBid !== undefined && d.highestBid !== undefined) {
    deletes.push("highestBid");
  }

  if (
    (d.currentHighBidderId === undefined || d.currentHighBidderId === "") &&
    d.highestBidderId
  ) {
    updates.currentHighBidderId = d.highestBidderId;
    deletes.push("highestBidderId");
  } else if (d.currentHighBidderId && d.highestBidderId !== undefined) {
    deletes.push("highestBidderId");
  }

  const needsBidCountQuery = d.bidCount === undefined || d.bidCount === null;

  if (
    Object.keys(updates).length === 0 &&
    deletes.length === 0 &&
    !needsBidCountQuery
  ) {
    return null;
  }

  return { lotId, updates, deletes, needsBidCountQuery };
}

async function migrateLotsForward(
  opts: {
    dryRun: boolean;
    skipBackup: boolean;
    maxOpsPerBatch: number;
  },
  metrics: MigrationMetrics
): Promise<void> {
  const { dryRun, skipBackup, maxOpsPerBatch } = opts;
  if (!dryRun && skipBackup) {
    console.warn(
      "[warn] --skip-backup: you will NOT be able to roll back lot field changes. Not recommended."
    );
  }

  let lastDoc: admin.firestore.QueryDocumentSnapshot | null = null;
  const pageSize = Math.min(DEFAULT_PAGE_SIZE, maxOpsPerBatch);

  while (true) {
    let q = db.collection("lots").orderBy(admin.firestore.FieldPath.documentId()).limit(pageSize);
    if (lastDoc) q = q.startAfter(lastDoc);

    const snap = await withRetry("lots page query", () => q.get());
    if (snap.empty) break;

    const batch = new OpBatch(db);

    for (const doc of snap.docs) {
      metrics.processed++;
      const d = doc.data();
      const plan = planLotMigration(doc.id, d);
      if (!plan) {
        metrics.skipped++;
        continue;
      }

      let updates = { ...plan.updates };
      const deletes = [...plan.deletes];

      if (plan.needsBidCountQuery) {
        try {
          const bc = await withRetry(`bidCount lot=${doc.id}`, () =>
            db.collection("bids").where("lotId", "==", doc.id).count().get()
          );
          updates.bidCount = bc.data().count;
        } catch (e) {
          metrics.errors++;
          const msg = `lot ${doc.id}: bidCount query failed: ${e instanceof Error ? e.message : e}`;
          metrics.errorDetails.push(msg);
          console.error(msg);
          metrics.skipped++;
          continue;
        }
      }

      const payload: Record<string, unknown> = { ...updates };
      for (const f of deletes) {
        payload[f] = admin.firestore.FieldValue.delete();
      }

      const backupRef = db.collection(LOT_BACKUP_COLLECTION).doc(doc.id);
      const { present, missing } = pickLotBackupFields(d);

      if (dryRun) {
        console.log(
          `[dry-run] lot ${doc.id} would update: ${JSON.stringify({
            set: updates,
            delete: deletes,
          })} backupKeys: present=${Object.keys(present).join(",")} missing=${missing.join(",")}`
        );
        metrics.updated++;
        continue;
      }

      if (!skipBackup) {
        const backupDoc = {
          version: BACKUP_VERSION,
          kind: "lot_field_normalize",
          lotId: doc.id,
          savedAt: admin.firestore.FieldValue.serverTimestamp(),
          present,
          missing,
        };
        const backupOps = 1;
        const updateOps = 1;
        await flushIfNeeded(batch, maxOpsPerBatch, backupOps + updateOps, "lots");
        batch.set(backupRef, backupDoc);
        batch.update(
          doc.ref,
          payload as admin.firestore.UpdateData<admin.firestore.DocumentData>
        );
        metrics.updated++;
      } else {
        await flushIfNeeded(batch, maxOpsPerBatch, 1, "lots");
        batch.update(
          doc.ref,
          payload as admin.firestore.UpdateData<admin.firestore.DocumentData>
        );
        metrics.updated++;
      }
    }

    if (!dryRun && batch.size > 0) {
      await batch.commit(maxOpsPerBatch, "lots-final-page");
    }

    lastDoc = snap.docs[snap.docs.length - 1]!;
    if (snap.size < pageSize) break;
  }
}

// ---------------------------------------------------------------------------
// Forward: bids → subcollections
// ---------------------------------------------------------------------------

function bidPayloadFromRoot(
  d: admin.firestore.DocumentData,
  lotId: string,
  bidId: string
): Record<string, unknown> {
  const created = ts(d.createdAt) ?? ts(d.timestamp) ?? admin.firestore.Timestamp.now();
  return {
    userId: d.userId ?? "",
    auctionId: d.auctionId ?? "",
    lotId,
    amount: d.amount ?? 0,
    status: d.status ?? "outbid",
    isAutoExtended: d.isAutoExtended === true,
    createdAt: created,
    migratedFromRootAt: admin.firestore.FieldValue.serverTimestamp(),
    migratedFromRootBidId: bidId,
  };
}

function bidsRoughlyEqual(
  a: admin.firestore.DocumentData,
  b: Record<string, unknown>
): boolean {
  const amt = (x: unknown) => (typeof x === "number" ? x : Number(x));
  return (
    String(a.userId ?? "") === String(b.userId ?? "") &&
    Math.abs(amt(a.amount) - amt(b.amount)) < 1e-9 &&
    String(a.lotId ?? "") === String(b.lotId ?? "")
  );
}

async function migrateBidsForward(
  opts: {
    dryRun: boolean;
    skipBackup: boolean;
    maxOpsPerBatch: number;
  },
  metrics: MigrationMetrics
): Promise<void> {
  const { dryRun, skipBackup, maxOpsPerBatch } = opts;
  let lastDoc: admin.firestore.QueryDocumentSnapshot | null = null;
  const pageSize = Math.min(DEFAULT_PAGE_SIZE, maxOpsPerBatch);

  while (true) {
    let q = db.collection("bids").orderBy(admin.firestore.FieldPath.documentId()).limit(pageSize);
    if (lastDoc) q = q.startAfter(lastDoc);

    const snap = await withRetry("bids page query", () => q.get());
    if (snap.empty) break;

    const batch = new OpBatch(db);

    for (const doc of snap.docs) {
      metrics.processed++;
      const d = doc.data();
      const lotId = typeof d.lotId === "string" ? d.lotId.trim() : "";
      if (!lotId) {
        metrics.skipped++;
        const msg = `bid ${doc.id}: missing lotId`;
        metrics.errorDetails.push(msg);
        console.warn(msg);
        continue;
      }

      const subRef = db.collection("lots").doc(lotId).collection("bids").doc(doc.id);
      const nextPayload = bidPayloadFromRoot(d, lotId, doc.id);

      if (dryRun) {
        console.log(
          `[dry-run] bid ${doc.id} → lots/${lotId}/bids/${doc.id} payload keys=${Object.keys(nextPayload).join(",")}`
        );
        metrics.updated++;
        continue;
      }

      try {
        const subSnap = await withRetry(`get sub bid ${doc.id}`, () => subRef.get());
        if (subSnap.exists) {
          const existing = subSnap.data() ?? {};
          if (bidsRoughlyEqual(existing, nextPayload)) {
            await flushIfNeeded(batch, maxOpsPerBatch, 1, "bids");
            batch.delete(doc.ref);
            metrics.updated++;
            continue;
          }
          metrics.skipped++;
          const msg = `bid ${doc.id}: sub doc exists with different data; skip (manual)`;
          metrics.errorDetails.push(msg);
          console.warn(msg);
          continue;
        }
      } catch (e) {
        metrics.errors++;
        const msg = `bid ${doc.id}: read sub failed: ${e instanceof Error ? e.message : e}`;
        metrics.errorDetails.push(msg);
        console.error(msg);
        continue;
      }

      const backupRef = db.collection(BID_BACKUP_COLLECTION).doc(doc.id);
      const rootSnapshot = { ...d };

      const backupOps = skipBackup ? 0 : 1;
      const writeOps = 1 + 1; // set sub + delete root
      const totalOps = backupOps + writeOps;

      await flushIfNeeded(batch, maxOpsPerBatch, totalOps, "bids");

      if (!skipBackup) {
        batch.set(backupRef, {
          version: BACKUP_VERSION,
          kind: "bid_root_move",
          bidId: doc.id,
          lotId,
          savedAt: admin.firestore.FieldValue.serverTimestamp(),
          rootData: rootSnapshot,
        });
      }
      batch.set(subRef, nextPayload, { merge: true });
      batch.delete(doc.ref);
      metrics.updated++;
    }

    if (!dryRun && batch.size > 0) {
      await batch.commit(maxOpsPerBatch, "bids-final-page");
    }

    lastDoc = snap.docs[snap.docs.length - 1]!;
    if (snap.size < pageSize) break;
  }
}

// ---------------------------------------------------------------------------
// Rollback
// ---------------------------------------------------------------------------

async function rollbackLots(
  opts: { dryRun: boolean; maxOpsPerBatch: number },
  metrics: MigrationMetrics
): Promise<void> {
  const { dryRun, maxOpsPerBatch } = opts;
  let lastDoc: admin.firestore.QueryDocumentSnapshot | null = null;
  const pageSize = DEFAULT_PAGE_SIZE;

  while (true) {
    let q = db
      .collection(LOT_BACKUP_COLLECTION)
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(pageSize);
    if (lastDoc) q = q.startAfter(lastDoc);

    const snap = await withRetry("lot_backups page", () => q.get());
    if (snap.empty) break;

    const batch = new OpBatch(db);

    for (const bdoc of snap.docs) {
      metrics.processed++;
      const b = bdoc.data();
      if (b.version !== BACKUP_VERSION || b.kind !== "lot_field_normalize") {
        metrics.skipped++;
        continue;
      }
      const lotId = String(b.lotId ?? bdoc.id);
      const present = (b.present ?? {}) as Record<string, unknown>;
      const missing = (b.missing ?? []) as string[];
      const lotRef = db.collection("lots").doc(lotId);
      const rollbackUpdate = buildLotRollbackUpdate({ present, missing });

      if (dryRun) {
        console.log(`[dry-run] rollback lot ${lotId} keys restore=${Object.keys(rollbackUpdate).length}`);
        metrics.updated++;
        continue;
      }

      await flushIfNeeded(batch, maxOpsPerBatch, 1, "rollback-lots");
      batch.update(
        lotRef,
        rollbackUpdate as admin.firestore.UpdateData<admin.firestore.DocumentData>
      );
      metrics.updated++;
    }

    if (!dryRun && batch.size > 0) {
      await batch.commit(maxOpsPerBatch, "rollback-lots-page");
    }

    lastDoc = snap.docs[snap.docs.length - 1]!;
    if (snap.size < pageSize) break;
  }
}

async function rollbackBids(
  opts: { dryRun: boolean; maxOpsPerBatch: number },
  metrics: MigrationMetrics
): Promise<void> {
  const { dryRun, maxOpsPerBatch } = opts;
  let lastDoc: admin.firestore.QueryDocumentSnapshot | null = null;
  const pageSize = DEFAULT_PAGE_SIZE;

  while (true) {
    let q = db
      .collection(BID_BACKUP_COLLECTION)
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(pageSize);
    if (lastDoc) q = q.startAfter(lastDoc);

    const snap = await withRetry("bid_backups page", () => q.get());
    if (snap.empty) break;

    const batch = new OpBatch(db);

    for (const bdoc of snap.docs) {
      metrics.processed++;
      const b = bdoc.data();
      if (b.version !== BACKUP_VERSION || b.kind !== "bid_root_move") {
        metrics.skipped++;
        continue;
      }
      const bidId = String(b.bidId ?? bdoc.id);
      const lotId = String(b.lotId ?? "");
      const rootData = b.rootData as admin.firestore.DocumentData | undefined;
      if (!lotId || !rootData) {
        metrics.errors++;
        metrics.errorDetails.push(`backup ${bdoc.id}: missing lotId or rootData`);
        continue;
      }

      const rootRef = db.collection("bids").doc(bidId);
      const subRef = db.collection("lots").doc(lotId).collection("bids").doc(bidId);

      if (dryRun) {
        console.log(`[dry-run] rollback bid ${bidId} → root bids/${bidId}, delete sub`);
        metrics.updated++;
        continue;
      }

      await flushIfNeeded(batch, maxOpsPerBatch, 2, "rollback-bids");
      batch.set(rootRef, rootData, { merge: false });
      batch.delete(subRef);
      metrics.updated++;
    }

    if (!dryRun && batch.size > 0) {
      await batch.commit(maxOpsPerBatch, "rollback-bids-page");
    }

    lastDoc = snap.docs[snap.docs.length - 1]!;
    if (snap.size < pageSize) break;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const { dryRun, rollback, phase, skipBackup, maxOpsPerBatch } = args;

  console.log(
    JSON.stringify({
      message: "migrateAuctionSchema starting",
      dryRun,
      rollback,
      phase,
      skipBackup,
      maxOpsPerBatch,
      lotBackupCollection: LOT_BACKUP_COLLECTION,
      bidBackupCollection: BID_BACKUP_COLLECTION,
    })
  );

  if (!dryRun && !rollback && skipBackup) {
    if (process.env.MIGRATE_ALLOW_NO_BACKUP !== "1") {
      console.error(
        "Refusing forward migration with --skip-backup (no rollback). " +
          "Omit --skip-backup, or set MIGRATE_ALLOW_NO_BACKUP=1 for break-glass only."
      );
      process.exit(2);
    }
    console.warn("[warn] MIGRATE_ALLOW_NO_BACKUP=1 — no backups; rollback will not be possible for this run.");
  }

  if (rollback) {
    const mBids = createMetrics();
    console.log("Rollback: bids first (root restore + delete sub)…");
    await rollbackBids({ dryRun, maxOpsPerBatch }, mBids);
    logMetrics("rollback_bids", mBids);

    const mLots = createMetrics();
    console.log("Rollback: lots from backups…");
    await rollbackLots({ dryRun, maxOpsPerBatch }, mLots);
    logMetrics("rollback_lots", mLots);

    console.log(
      dryRun
        ? "Rollback dry run finished (no writes)."
        : "Rollback finished. Verify data; backup docs were NOT deleted (remove manually if desired)."
    );
    return;
  }

  if (phase === "lots" || phase === "all") {
    const m = createMetrics();
    console.log("Phase: migrate lots…");
    await migrateLotsForward({ dryRun, skipBackup: dryRun ? true : skipBackup, maxOpsPerBatch }, m);
    logMetrics("forward_lots", m);
  }

  if (phase === "bids" || phase === "all") {
    const m = createMetrics();
    console.log("Phase: migrate root bids → subcollections…");
    await migrateBidsForward({ dryRun, skipBackup: dryRun ? true : skipBackup, maxOpsPerBatch }, m);
    logMetrics("forward_bids", m);
  }

  console.log(
    dryRun
      ? "Dry run complete. Review logs, then run without --dry-run."
      : "Forward migration complete. Deploy Functions + rules + indexes; optional: delete backup collections after verification."
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
