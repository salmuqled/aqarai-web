# Bulletproof financial architecture — design specification

**Status:** Production target. **Verdict on current app:** `ERROR` — dual truth (`isCommissionPaid` vs `company_payments`) until migration completes.

---

## 1) Text architecture diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ACCRUAL (earned / recognized)                    │
├─────────────────────────────────────────────────────────────────────────┤
│  deals (finalized)          auction_requests (fee earned when policy     │
│  commissionAmount (due)      says fee is recognized — e.g. status paid)   │
│  commissionRecognizedAt      auctionFee, auctionFeeStatus                 │
│  finalPrice, dealStatus                                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │  Dashboard: "Revenue" = sum(accrual)
                                    │  (split dimensions: commission vs fee)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         CASH (collected — bank/cash)                     │
├─────────────────────────────────────────────────────────────────────────┤
│  company_payments (append-only; void = status rejected)                  │
│  amount, status, type, relatedType, relatedId, idempotencyKey, …        │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │  Cloud Function (transaction):
                                    │  on confirm → validate → update deal
                                    │  mirror fields on deal (derived)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  deals (SERVER-WRITTEN MIRRORS — not client-editable)                    │
│  commissionPaidTotalKwd, commissionPaymentStatus,                       │
│  commissionLastPaymentAt, commissionOverpaidKwd                         │
│  [legacy read compat] isCommissionPaid / commissionPaidAt = CF only     │
└─────────────────────────────────────────────────────────────────────────┘
```

**Single source of truth**

| Concept | Source of truth | Never trust |
|--------|-----------------|-------------|
| **Earned commission (per deal)** | `deals.commissionAmount` (canonical) | Client-computed flags |
| **Earned auction fee (per request)** | `auction_requests` policy + fields | Duplicate “revenue” in deals |
| **Cash received** | Sum of `company_payments` where `status == confirmed` | `isCommissionPaid` alone |

---

## 2) Removed / frozen fields (client)

| Field | Verdict |
|-------|---------|
| `isCommissionPaid` | **ERROR** if client-writable — **remove from client writes**; mirror only via Functions |
| `commission` (duplicate of `commissionAmount`) | **ERROR** long-term — **deprecate**; keep read fallback in code until backfill |
| `commissionPaidAt` | **Server-only** (set when status becomes `paid` / first full payment) |

---

## 3) New / canonical deal fields

| Field | Type | Writer |
|-------|------|--------|
| `commissionAmount` | number | Admin pipeline when final price/commission fixed (single canonical due) |
| `commissionRecognizedAt` | timestamp | Optional: set when deal enters `signed`/`closed` with due &gt; 0 |
| `commissionPaidTotalKwd` | number | **Cloud Functions only** — running sum of confirmed `type==commission` payments |
| `commissionPaymentStatus` | string | **CF only** — `unpaid` \| `partial` \| `paid` \| `overpaid` \| `not_applicable` |
| `commissionLastPaymentAt` | timestamp | **CF only** |
| `commissionOverpaidKwd` | number | **CF only** — `max(0, paid - due)` |

Legacy UI may keep reading `isCommissionPaid` until Flutter migrates to `commissionPaymentStatus in ('paid','overpaid')`.

---

## 4) `company_payments` strict contract

**Required on create (admin):** `amount`, `status`, `type`, `reason`, `source`, `relatedType`, `notes`, `createdBy`, `updatedBy`, `createdAt`, and linkage per type (already in `firestore.rules`).

**Recommended additions (migration):**

| Field | Type | Rule |
|-------|------|------|
| `idempotencyKey` | string | Optional UUID per logical payment; **unique** when present (enforce via CF or composite index + CF) |
| `currency` | string | Default `KWD` |
| `externalReference` | string | Bank ref (may equal doc id for bank/check) |

**Validation (enforced in CF on confirm, in addition to rules):**

- `type === 'commission'` ⇒ `relatedType === 'deal'` and `relatedId` exists and deal exists and `dealStatus in ('signed','closed')`.
- `amount > 0`.
- On transition to `confirmed`: deal `commissionPaidTotalKwd` updated in **transaction**.

---

## 5) Dashboard formulas (no double count)

Define **buckets** explicitly:

### Total recognized revenue (accrual)

```
R_commission = Σ deals.commissionAmount  (or getCommission() during migration)
               where dealStatus in ('signed','closed')
               AND commissionAmount > 0

R_auction_fees = Σ auction_requests.auctionFee
                 where auctionFeeStatus == 'paid'   // per your product definition

R_total = R_commission + R_auction_fees
```

**ERROR** if you add auction fees from both `auction_requests` **and** `company_payments.type == auction_fee` into the same `R_auction_fees` without defining whether the ledger row is **the** recognition or a **cash mirror** — pick one model:

- **Model A (recommended):** Accrual from **operational docs** (`auction_requests`, `deals`); `company_payments` is **cash only** — cash dashboard compares `R_total` vs sum(confirmed payments) **by type**, not by mixing meanings.
- **Model B:** Accrual **only** from ledger — then operational docs must not feed revenue (heavier migration).

### Total collected (cash)

```
C_total = Σ company_payments.amount where status == 'confirmed'

C_commission = same filter AND type == 'commission'
C_auction    = same filter AND type == 'auction_fee'
C_other      = same filter AND type == 'other'
```

### Outstanding (commission AR only — recommended card)

```
Outstanding_commission = R_commission - C_commission
```

Use **not** `R_total - C_total` unless you also split “other” cash that has no accrual line (management fees) — otherwise **ERROR** (misleading remainder).

---

## 6) Edge cases matrix

| Case | Handling |
|------|----------|
| Partial payments | `commissionPaidTotalKwd` sums payments; `commissionPaymentStatus = partial` |
| Overpayment | `commissionOverpaidKwd = paid - due`; status `overpaid`; optional alert |
| Duplicate payment rows | Two docs ⇒ two adds; prevent **logical** dup with `idempotencyKey` + CF reject |
| Missing payment (deal closed) | Accrual shows due; `commissionPaidTotalKwd` &lt; due ⇒ outstanding |
| Payment exists, deal not updated | **CF transaction** is authoritative; add **reconcile** callable to re-sum |
| Status confirmed → rejected | CF **subtracts** amount from `commissionPaidTotalKwd` |
| Float noise | Compare with ε = 0.005 KWD |

---

## 7) Migration plan (step-by-step)

1. **Deploy** Cloud Function `onCompanyPaymentDealFinancialSync` + Firestore rules (server-only deal financial keys).
2. **Backfill** `deals.commissionAmount` from `max(commission, commissionAmount)` where missing.
3. **One-time script** (Admin SDK): for each deal with finalized status, query `company_payments` where `type==commission`, `relatedId==dealId`, `status==confirmed`, sum amounts → write `commissionPaidTotalKwd` + derived status.
4. **Update Flutter:** stop calling `setCommissionPaid` / remove `isCommissionPaid` from UI logic; use `commissionPaymentStatus` or derived from `commissionPaidTotalKwd` vs `commissionAmount`.
5. **Remove** duplicate `commission` writes in app (write only `commissionAmount`).
6. **Optional:** Callable `submitCompanyPayment` as only create path (strongest).

---

## 8) Files implemented in repo

- `functions/src/financial/dealPaymentStatus.ts` — pure helpers
- `functions/src/financial/onPaymentConfirmedDealSync.ts` — Firestore trigger
- `functions/src/index.ts` — export
- `firestore.rules` — deals update guard for server financial fields

---

## 9) Final verdict system

| Check | Result |
|-------|--------|
| Single accrual source per instrument | **PASS** after `commissionAmount` only |
| Single cash source | **PASS** — `company_payments` |
| No client-fake paid flags | **PASS** after rules + CF |
| Reversible confirm/reject | **PASS** with subtract path |
| Dashboard semantics explicit | **PASS** if formulas use split cards |

**Overall:** **SAFE** after migration + Flutter admin changes to stop writing legacy flags.
