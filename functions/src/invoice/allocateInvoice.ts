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

  await db.runTransaction(async (tx) => {
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

    tx.set(seqRef, { n: next, year, updatedAt: FieldValue.serverTimestamp() }, {
      merge: true,
    });

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

  return out;
}
