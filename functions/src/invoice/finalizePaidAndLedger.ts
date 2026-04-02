/**
 * Marks invoice as paid (from issued) and creates idempotent financial_ledger row (doc id = invoice id).
 */
import { FieldValue, type DocumentReference, type Firestore } from "firebase-admin/firestore";

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

export async function commitFinalizePaidAndLedger(
  db: Firestore,
  invoiceRef: DocumentReference,
  paymentId: string
): Promise<void> {
  await db.runTransaction(async (tx) => {
    const invSnap = await tx.get(invoiceRef);
    if (!invSnap.exists) return;
    const d = invSnap.data() as Record<string, unknown>;
    const st = str(d.status);
    if (st === "cancelled") return;

    const ledgerRef = db.collection("financial_ledger").doc(invoiceRef.id);
    const ledSnap = await tx.get(ledgerRef);
    const amount = num(d.amount);
    const companyId = str(d.companyId);

    if (!ledSnap.exists && amount > 0) {
      tx.set(ledgerRef, {
        id: ledgerRef.id,
        type: "income",
        amount,
        currency: "KWD",
        source: "invoice",
        invoiceId: invoiceRef.id,
        paymentId,
        companyId,
        createdAt: FieldValue.serverTimestamp(),
      });
    }

    if (st === "issued") {
      tx.update(invoiceRef, {
        status: "paid",
        paidAt: FieldValue.serverTimestamp(),
      });
    }
  });
}

/**
 * Marks invoice paid. Creates a ledger row at [invoiceRef.id] only if no invoice-ledger
 * row exists for this [paymentId] yet (recreate flow: keep single ledger line per payment).
 */
export async function commitFinalizePaidRespectingExistingLedgerByPayment(
  db: Firestore,
  invoiceRef: DocumentReference,
  paymentId: string
): Promise<void> {
  await db.runTransaction(async (tx) => {
    const invSnap = await tx.get(invoiceRef);
    if (!invSnap.exists) return;
    const d = invSnap.data() as Record<string, unknown>;
    const st = str(d.status);
    if (st === "cancelled") return;

    const ledQ = await tx.get(
      db
        .collection("financial_ledger")
        .where("paymentId", "==", paymentId)
        .limit(20)
    );

    const hasInvoiceLedgerForPayment = ledQ.docs.some((doc) => {
      const x = doc.data() as Record<string, unknown>;
      return str(x.type) === "income" && str(x.source) === "invoice";
    });

    const ledgerRef = db.collection("financial_ledger").doc(invoiceRef.id);
    const ledSnap = await tx.get(ledgerRef);
    const amount = num(d.amount);
    const companyId = str(d.companyId);

    if (!hasInvoiceLedgerForPayment && !ledSnap.exists && amount > 0) {
      tx.set(ledgerRef, {
        id: ledgerRef.id,
        type: "income",
        amount,
        currency: "KWD",
        source: "invoice",
        invoiceId: invoiceRef.id,
        paymentId,
        companyId,
        createdAt: FieldValue.serverTimestamp(),
      });
    }

    if (st === "issued") {
      tx.update(invoiceRef, {
        status: "paid",
        paidAt: FieldValue.serverTimestamp(),
      });
    }
  });
}
