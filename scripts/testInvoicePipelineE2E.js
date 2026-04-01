/**
 * E2E: company_payments (confirmed) → onCompanyPaymentConfirmedInvoice
 *
 * Prerequisites:
 *   - Deploy: firebase deploy --only functions:onCompanyPaymentConfirmedInvoice
 *   - INVOICE_SMTP_PASS secret (Gmail App Password) for emailSent; else emailError is expected.
 *
 *   cd scripts && export FIREBASE_UID="<admin_auth_uid>" && node testInvoicePipelineE2E.js
 */

const admin = require("firebase-admin");
const crypto = require("crypto");
const path = require("path");
const fs = require("fs");

function resolveServiceAccountPath() {
  const fromEnv = process.env.SERVICE_ACCOUNT_JSON;
  if (fromEnv && fs.existsSync(fromEnv)) return path.resolve(fromEnv);
  const exact = path.join(__dirname, "serviceAccountKey.json");
  if (fs.existsSync(exact)) return exact;
  console.error("Missing service account key");
  process.exit(1);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function findAdminUid() {
  const env = (process.env.FIREBASE_UID || "").trim();
  if (env) return env;
  let next;
  for (let i = 0; i < 20; i++) {
    const r = await admin.auth().listUsers(1000, next);
    for (const u of r.users) {
      if (u.customClaims && u.customClaims.admin === true) return u.uid;
    }
    next = r.pageToken;
    if (!next) break;
  }
  throw new Error("No admin user; set FIREBASE_UID");
}

async function verifyPdfUrl(url) {
  try {
    const res = await fetch(url, { method: "GET", redirect: "follow" });
    const ct = res.headers.get("content-type") || "";
    const buf = await res.arrayBuffer();
    return {
      ok: res.ok && buf.byteLength > 1000 && ct.includes("pdf"),
      status: res.status,
      bytes: buf.byteLength,
      contentType: ct,
    };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

async function loadLedgerInvoiceSummary(db) {
  const snap = await db
    .collection("financial_ledger")
    .where("type", "==", "income")
    .where("source", "==", "invoice")
    .orderBy("createdAt", "desc")
    .limit(500)
    .get();
  let total = 0;
  let count = 0;
  snap.forEach((d) => {
    count++;
    const a = d.data().amount;
    total += typeof a === "number" ? a : parseFloat(a) || 0;
  });
  return { total, count };
}

/** Same query as AdminInvoicesService.loadGlobalSummary — needs composite index (may be building). */
async function tryLedgerSummary(db) {
  try {
    return { ok: true, ...(await loadLedgerInvoiceSummary(db)) };
  } catch (e) {
    const msg = String(e.message || e);
    if (msg.includes("index")) {
      return { ok: false, reason: msg };
    }
    throw e;
  }
}

async function main() {
  const keyPath = resolveServiceAccountPath();
  if (!admin.apps.length) {
    admin.initializeApp({
      credential: admin.credential.cert(require(keyPath)),
    });
  }
  const db = admin.firestore();
  const createdBy = await findAdminUid();
  const paymentId = `e2e_${crypto.randomBytes(8).toString("hex")}`;
  const amount = 18.5;

  const payment = {
    amount,
    status: "confirmed",
    type: "other",
    reason: "sale",
    source: "cash",
    relatedType: "manual",
    notes: "E2E invoice+ledger pipeline (scripts/testInvoicePipelineE2E.js)",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdBy,
    updatedBy: createdBy,
  };

  console.log("STEP 1: company_payments/" + paymentId + " (confirmed, manual, amount=" + amount + ")");
  await db.collection("company_payments").doc(paymentId).set(payment);

  console.log("STEP 2: Waiting for onCompanyPaymentConfirmedInvoice …");
  const deadline = Date.now() + 300000;
  let invoiceDoc = null;
  while (Date.now() < deadline) {
    const q = await db
      .collection("invoices")
      .where("paymentId", "==", paymentId)
      .limit(1)
      .get();
    if (!q.empty) {
      invoiceDoc = q.docs[0];
      break;
    }
    await sleep(2500);
  }

  if (!invoiceDoc) {
    console.error(
      "TIMEOUT: no invoice. Deploy the trigger:\n" +
        "  firebase deploy --only functions:onCompanyPaymentConfirmedInvoice"
    );
    process.exit(2);
  }

  const invId = invoiceDoc.id;
  const inv = invoiceDoc.data();

  console.log("\nSTEP 3a — Invoice");
  console.log("  id:", invId, "invoiceNumber:", inv.invoiceNumber);
  console.log(
    "  status:",
    inv.status,
    "(final state; `issued` is set inside allocateInvoice then immediately advanced to `paid` in commitFinalizePaidAndLedger in the same CF invocation)"
  );
  if (String(inv.status).toLowerCase() !== "paid") {
    console.error("FAIL: expected status paid");
    process.exit(3);
  }

  console.log("\nSTEP 3b — financial_ledger (doc id = invoice id, no duplicate key)");
  const led = await db.collection("financial_ledger").doc(invId).get();
  if (!led.exists) {
    console.error("FAIL: missing financial_ledger/" + invId);
    process.exit(4);
  }
  const L = led.data();
  const ledgerOk =
    L.type === "income" &&
    L.source === "invoice" &&
    Number(L.amount) === amount &&
    L.invoiceId === invId &&
    L.paymentId === paymentId;
  if (!ledgerOk) {
    console.error("FAIL: ledger fields", L);
    process.exit(5);
  }
  console.log("  OK type/income, source=invoice, amount matches");

  console.log("\nSTEP 3c — PDF (Storage) — wait until pdfUrl or pdfError (async after ledger)");
  let pdfUrl = "";
  let invLatest = inv;
  const pdfDeadline = Date.now() + 120000;
  while (Date.now() < pdfDeadline) {
    const snap = await db.collection("invoices").doc(invId).get();
    invLatest = snap.data() || {};
    pdfUrl = String(invLatest.pdfUrl || "").trim();
    if (pdfUrl.length > 20) break;
    if (invLatest.pdfError && String(invLatest.pdfError).length > 2) {
      console.error("FAIL: PDF pipeline error:", invLatest.pdfError);
      process.exit(6);
    }
    await sleep(2000);
  }
  if (pdfUrl.length < 20) {
    console.error("FAIL: pdfUrl still missing after wait; pdfError:", invLatest.pdfError || "(none)");
    process.exit(6);
  }
  const pdfCheck = await verifyPdfUrl(pdfUrl);
  console.log("  pdfUrl GET:", pdfCheck.ok ? "OK" : "FAIL", pdfCheck);
  if (!pdfCheck.ok) process.exit(7);

  console.log("\nSTEP 3d — Email");
  if (invLatest.emailSent === true) {
    console.log("  emailSent: true");
  } else if (invLatest.emailError && String(invLatest.emailError).length > 5) {
    console.log("  emailSent: false; emailError logged (SMTP/credentials):", String(invLatest.emailError).slice(0, 120) + "…");
  } else {
    console.log("  emailSent:", invLatest.emailSent, "emailError:", invLatest.emailError ?? "(none)");
  }

  console.log("\nSTEP 4 — Admin dashboard data (AdminInvoicesService.loadGlobalSummary; needs financial_ledger index)");
  const summaryAfter = await tryLedgerSummary(db);
  if (summaryAfter.ok) {
    console.log("  ledger invoice rows:", summaryAfter.count, "sum KWD:", summaryAfter.total);
    const includesNew = summaryAfter.total >= amount - 0.001;
    console.log("  rollup includes at least this payment amount:", includesNew);
  } else {
    console.log("  SKIP composite rollup (index missing or still building):");
    console.log(" ", summaryAfter.reason.slice(0, 200));
    console.log("  Verified instead: financial_ledger/" + invId + " amount=" + amount);
  }
  const listed = await db
    .collection("invoices")
    .orderBy("createdAt", "desc")
    .limit(20)
    .get();
  const inList = listed.docs.some((d) => d.id === invId);
  console.log("  invoice appears in recent 20 by createdAt:", inList);

  console.log("\n========== RESULT ==========");
  console.log("PASS: payment → invoice paid → ledger → PDF downloadable.");
  console.log("UI: Admin → Invoices → open row → status paid → open PDF (same pdfUrl).");
  console.log("paymentId:", paymentId, "invoiceId:", invId);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
