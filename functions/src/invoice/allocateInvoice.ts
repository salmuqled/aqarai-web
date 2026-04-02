import {
  FieldValue,
  type DocumentReference,
  type Firestore,
} from "firebase-admin/firestore";

function kuwaitYear(d = new Date()): number {
  return parseInt(
    new Intl.DateTimeFormat("en-US", {
      timeZone: "Asia/Kuwait",
      year: "numeric",
    }).format(d),
    10
  );
}

export interface AllocatedInvoice {
  invoiceRef: DocumentReference;
  invoiceNumber: string;
  year: number;
}

/**
 * Idempotent: one invoice per [paymentId] via Firestore transaction + sequence counter.
 */
export async function allocateInvoiceInTransaction(
  db: Firestore,
  paymentId: string,
  buildPayload: () => Record<string, unknown>
): Promise<AllocatedInvoice | null> {
  const year = kuwaitYear();
  const seqRef = db.collection("system").doc(`invoice_seq_${year}`);

  let out: AllocatedInvoice | null = null;

  try {
    await db.runTransaction(async (tx) => {
      // --- all reads first ---
      const dup = await tx.get(
        db.collection("invoices").where("paymentId", "==", paymentId).limit(1)
      );
      if (!dup.empty) {
        out = null;
        return;
      }

      const seqSnap = await tx.get(seqRef);
      const prev = seqSnap.data()?.n;
      const next =
        typeof prev === "number" && !Number.isNaN(prev)
          ? prev + 1
          : 1;

      const invoiceNumber = `INV-KWT-${year}-${String(next).padStart(4, "0")}`;
      const invoiceRef = db.collection("invoices").doc();

      // --- writes only after all reads ---
      tx.set(
        seqRef,
        { n: next, year, updatedAt: FieldValue.serverTimestamp() },
        { merge: true }
      );

      const payload = buildPayload();
      tx.set(invoiceRef, {
        ...payload,
        id: invoiceRef.id,
        invoiceNumber,
        paymentId,
        invoiceYear: year,
        createdAt: FieldValue.serverTimestamp(),
      });

      out = { invoiceRef, invoiceNumber, year };
    });
  } catch (err) {
    console.error(
      "allocateInvoiceInTransaction: Firestore transaction failed",
      err
    );
    throw err;
  }

  return out;
}

/** Written on invoices cancelled by admin recreate flow (audit). */
export const INVOICE_CANCEL_REASON_RECREATE = "recreated_for_email_fix";

/**
 * Cancels every non-cancelled invoice for [paymentId], then allocates a new invoice row
 * (new doc id + new invoiceNumber). Does not touch financial_ledger.
 */
export async function cancelActiveInvoicesAndAllocateNewForPayment(
  db: Firestore,
  paymentId: string,
  buildPayload: () => Record<string, unknown>
): Promise<AllocatedInvoice | null> {
  const year = kuwaitYear();
  const seqRef = db.collection("system").doc(`invoice_seq_${year}`);

  let out: AllocatedInvoice | null = null;

  try {
    await db.runTransaction(async (tx) => {
      // --- all reads first ---
      const existing = await tx.get(
        db.collection("invoices").where("paymentId", "==", paymentId).limit(50)
      );
      if (existing.empty) {
        out = null;
        return;
      }

      const seqSnap = await tx.get(seqRef);
      const prev = seqSnap.data()?.n;
      const next =
        typeof prev === "number" && !Number.isNaN(prev) ? prev + 1 : 1;

      const invoiceNumber = `INV-KWT-${year}-${String(next).padStart(4, "0")}`;
      const invoiceRef = db.collection("invoices").doc();

      // --- writes only after all reads (was: tx.get(seqRef) after tx.update loop) ---
      for (const doc of existing.docs) {
        const st = String((doc.data() as Record<string, unknown>).status ?? "")
          .trim()
          .toLowerCase();
        if (st !== "cancelled") {
          tx.update(doc.ref, {
            status: "cancelled",
            cancelledAt: FieldValue.serverTimestamp(),
            cancelReason: INVOICE_CANCEL_REASON_RECREATE,
          });
        }
      }

      tx.set(
        seqRef,
        { n: next, year, updatedAt: FieldValue.serverTimestamp() },
        { merge: true }
      );

      const payload = buildPayload();
      tx.set(invoiceRef, {
        ...payload,
        id: invoiceRef.id,
        invoiceNumber,
        paymentId,
        invoiceYear: year,
        createdAt: FieldValue.serverTimestamp(),
      });

      out = { invoiceRef, invoiceNumber, year };
    });
  } catch (err) {
    console.error(
      "cancelActiveInvoicesAndAllocateNewForPayment: Firestore transaction failed",
      err
    );
    throw err;
  }

  return out;
}
