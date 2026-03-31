# AqarAi — Auction System (Firestore)

Production-oriented schema for ministry-approved real estate auctions (Kuwait).  
**Client services validate for UX; authoritative bid/deposit writes should be enforced via Cloud Functions + these rules.**

## Collections

### `auctions/{auctionId}`

| Field | Type | Notes |
|--------|------|--------|
| `title` | string | |
| `ministryApprovalNumber` | string | MoC reference |
| `startDate` | timestamp | |
| `endDate` | timestamp | |
| `status` | string | `draft` \| `registration_open` \| `closed` \| `live` \| `finished` |
| `createdBy` | string | Admin UID |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | optional, recommended |

### `lots/{lotId}`

| Field | Type | Notes |
|--------|------|--------|
| `auctionId` | string | Parent auction |
| `title` | string | e.g. Villa 1 |
| `description` | string | |
| `startingPrice` | number | |
| `minIncrement` | number | |
| `depositType` | string | `fixed` \| `percentage` |
| `depositValue` | number | Amount or % depending on type |
| `startTime` | timestamp | Lot window |
| `endTime` | timestamp | |
| `status` | string | `pending` \| `active` \| `closed` \| `sold` |
| `highestBid` | number | optional until first bid |
| `highestBidderId` | string | optional |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | optional |

**Invariant:** At most one `lot` per auction with `status == active` (enforced operationally + Functions).

### `auction_participants/{participantId}`

| Field | Type | Notes |
|--------|------|--------|
| `userId` | string | |
| `auctionId` | string | |
| `status` | string | `pending` \| `approved` \| `rejected` \| `blocked` |
| `approvedBy` | string | Admin UID |
| `approvedAt` | timestamp | |
| `notes` | string | optional |
| `createdAt` | timestamp | |

**Recommended composite uniqueness:** one doc per `(userId, auctionId)` — use deterministic ID `"{userId}_{auctionId}"` or query + enforce in Functions.

### `lot_permissions/{permissionId}`

| Field | Type | Notes |
|--------|------|--------|
| `userId` | string | |
| `lotId` | string | |
| `auctionId` | string | Denormalized for security rules & queries |
| `canBid` | bool | Eligibility (KYC / legal) |
| `isActive` | bool | **Live session only** — set false when lot ends |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | optional |

**Recommended ID:** `"{userId}_{lotId}"` for idempotent upserts.

### `deposits/{depositId}`

| Field | Type | Notes |
|--------|------|--------|
| `userId` | string | |
| `auctionId` | string | |
| `lotId` | string | |
| `amount` | number | |
| `type` | string | `fixed` \| `percentage` |
| `paymentStatus` | string | `pending` \| `paid` \| `failed` \| `refunded` \| `forfeited` |
| `paymentGateway` | string | e.g. `MyFatoorah` |
| `transactionId` | string | optional |
| `paidAt` | timestamp | optional |
| `refundedAt` | timestamp | optional |
| `createdAt` | timestamp | |

### `bids/{bidId}`

| Field | Type | Notes |
|--------|------|--------|
| `userId` | string | |
| `auctionId` | string | |
| `lotId` | string | |
| `amount` | number | |
| `timestamp` | timestamp | server-preferred |
| `status` | string | `valid` \| `rejected` \| `winning` |
| `isAutoExtended` | bool | |
| `createdAt` | timestamp | optional mirror |

### `auction_logs/{logId}`

| Field | Type | Notes |
|--------|------|--------|
| `auctionId` | string | |
| `lotId` | string | optional (auction-wide actions) |
| `action` | string | e.g. `bid_placed`, `lot_started`, `lot_closed`, `user_blocked` |
| `performedBy` | string | Admin UID or `system` |
| `details` | map | Arbitrary JSON-safe payload |
| `timestamp` | timestamp | |

## Indexes (suggested)

- `lots`: `auctionId` ASC + `status` ASC + `startTime` ASC  
- `auction_participants`: `auctionId` ASC + `status` ASC  
- `lot_permissions`: `lotId` ASC + `isActive` ASC  
- `lot_permissions`: `userId` ASC + `lotId` ASC  
- `deposits`: `userId` ASC + `lotId` ASC + `paymentStatus` ASC  
- `bids`: `lotId` ASC + `timestamp` DESC  
- `auction_logs`: `auctionId` ASC + `timestamp` DESC  

Add to `firestore.indexes.json` as you query in production.

## Security note

Bid placement and financial state transitions **must** be validated server-side (Callable/HTTPS + Admin SDK) to prevent tampering. Dart services here provide structure and client-side checks for responsiveness only.

### Callable: `placeAuctionBid` (region `us-central1`)

- **Input:** `{ auctionId, lotId, amount }` (authenticated caller UID from ID token).
- **Behavior:** Firestore transaction reads lot, participant, permission, deposit; validates; writes `bids`, updates `lots`, appends `auction_logs` (`action: bid_placed`).
- **Client:** `BidService.placeBid(...)` invokes this callable; direct `bids` creates remain denied in Firestore rules.
