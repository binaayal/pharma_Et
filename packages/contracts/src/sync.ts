import { z } from 'zod';
import { goodsReceiptPayload, salePayload } from './entities.js';
import {
  changeSeq,
  isoDate,
  quantity,
  santim,
  terminalSeq,
  utcTimestamp,
  uuidv7,
} from './primitives.js';
import { CONTRACT_VERSION } from './version.js';

/**
 * The sync envelope — docs/04-system-design.md §7, made executable.
 *
 * THIS IS A CONTROLLED ARTIFACT (docs/06-delivery-plan.md §7). Changing anything in this
 * file requires an ADR, contract tests on both sides including N-1 (ADR-009), a guardian
 * suite update, two reviews, and an RTM entry. Drift here does not throw an error — it
 * silently drops or duplicates a pharmacy's real transactions.
 */

/** Entity types a terminal may push. Grows per phase; see entities.ts. */
export const entityType = z.enum(['sale', 'goods_receipt']);
export type EntityType = z.infer<typeof entityType>;

/**
 * Writes are creates, updates, or TOMBSTONES. There is no delete: nothing in this system is
 * ever physically removed (ADR-002/004, NFR-5.3).
 */
export const opType = z.enum(['create', 'update', 'tombstone']);
export type OpType = z.infer<typeof opType>;

const operationBase = {
  /** Idempotency key. UNIQUE(tenant_id, op_id) server-side; replay is a no-op (AC-9.2). */
  opId: uuidv7,
  terminalId: uuidv7,
  /** The ordering key. Monotonic per terminal — never a wall clock (ADR-006). */
  terminalSeq,
  entityId: uuidv7,
  opType,
  /** Optimistic concurrency. Null on create. Single-writer should never conflict (BR-9.1). */
  baseVersion: z.number().int().nonnegative().nullable(),
  tenantId: uuidv7,
  branchId: uuidv7.nullable(),
  actorId: uuidv7,
  /** Recorded for forensics only. NOT used for ordering — device clocks are untrusted. */
  clientTs: utcTimestamp,
};

/**
 * One operation from a terminal's outbox, discriminated by `entityType` so the payload is
 * typed rather than an opaque blob — an untyped payload is how contract drift hides.
 */
export const operation = z.discriminatedUnion('entityType', [
  z.object({ ...operationBase, entityType: z.literal('sale'), payload: salePayload }),
  z.object({
    ...operationBase,
    entityType: z.literal('goods_receipt'),
    payload: goodsReceiptPayload,
  }),
]);
export type Operation = z.infer<typeof operation>;

/** POST /sync/push — an ordered batch drained from the outbox. */
export const pushRequest = z.object({
  contractVersion: z.string().default(CONTRACT_VERSION),
  terminalId: uuidv7,
  /** Ordered by terminalSeq ascending. The server applies them in the order given. */
  operations: z.array(operation).max(500),
});
export type PushRequest = z.infer<typeof pushRequest>;

/**
 * Per-operation result.
 *
 * - `applied`   — took effect now.
 * - `duplicate` — already applied; the client clears it. Not an error: this is what makes a
 *                 retried push after a dropped connection safe (AC-9.2).
 * - `rejected`  — could not be applied. Rare under single-writer because validation runs
 *                 locally first, but it must exist: the client parks it in a "needs
 *                 attention" queue rather than dropping a real transaction on the floor.
 */
export const ackStatus = z.enum(['applied', 'duplicate', 'rejected']);
export type AckStatus = z.infer<typeof ackStatus>;

export const ack = z.object({
  opId: uuidv7,
  status: ackStatus,
  serverVersion: z.number().int().nonnegative().nullable(),
  /** Human-readable cause. Required when rejected, so the queue entry is actionable. */
  reason: z.string().nullable(),
});
export type Ack = z.infer<typeof ack>;

export const pushResponse = z.object({
  contractVersion: z.string(),
  acks: z.array(ack),
  /** Current pull cursor, so a client can skip a redundant pull round-trip. */
  changeSeq,
});
export type PushResponse = z.infer<typeof pushResponse>;

/* -------------------------------------------------------------------------- */
/* Pull — reference data deltas (docs/04 §7.2)                                 */
/* -------------------------------------------------------------------------- */

/**
 * Reference data flows server -> client only. Transactional data flows client -> server via
 * push. Keeping the two directions disjoint is what makes single-writer V1 conflict-free.
 */

export const productRef = z.object({
  id: uuidv7,
  name: z.string(),
  unit: z.string(),
  isControlled: z.boolean(),
  psychotropicClass: z.string().nullable(),
  currentPriceSantim: santim.nonnegative(),
  changeSeq,
  deletedAt: utcTimestamp.nullable(),
});
export type ProductRef = z.infer<typeof productRef>;

export const branchRef = z.object({
  id: uuidv7,
  name: z.string(),
  address: z.string().nullable(),
  changeSeq,
  deletedAt: utcTimestamp.nullable(),
});
export type BranchRef = z.infer<typeof branchRef>;

export const userRef = z.object({
  id: uuidv7,
  displayName: z.string(),
  role: z.enum(['owner', 'branch_manager', 'cashier']),
  branchIds: z.array(uuidv7),
  changeSeq,
  deletedAt: utcTimestamp.nullable(),
});
export type UserRef = z.infer<typeof userRef>;

/**
 * Server-owned stock truth, pulled back to the terminal.
 *
 * The terminal decrements its own local copy on every sale, so this is a correction, not the
 * authority for whether a sale may proceed: a sale is NEVER blocked on stock for a standard
 * drug (BR-3.2). Controlled substances do not appear here at all — their stock is a
 * projection over the ledger (BR-3.3) and arrives in Phase 2.
 */
export const stockBatchRef = z.object({
  id: uuidv7,
  branchId: uuidv7,
  productId: uuidv7,
  lotNo: z.string(),
  expiryDate: isoDate,
  qtyOnHand: quantity,
  changeSeq,
  deletedAt: utcTimestamp.nullable(),
});
export type StockBatchRef = z.infer<typeof stockBatchRef>;

export const pullResponse = z.object({
  contractVersion: z.string(),
  /** Pass this back as `cursor` on the next pull. */
  cursor: changeSeq,
  /** True when more rows remain beyond this page; pull again immediately. */
  hasMore: z.boolean(),
  products: z.array(productRef),
  branches: z.array(branchRef),
  users: z.array(userRef),
  stockBatches: z.array(stockBatchRef),
  /** When the server produced this page — shown to the user as data currency (BR-9.4). */
  serverTime: utcTimestamp,
});
export type PullResponse = z.infer<typeof pullResponse>;

/**
 * GET /sync/pull query parameters.
 *
 * Coerced, because a query string carries everything as text: `?cursor=42` arrives as the
 * string "42". The coercion lives in the contract rather than in a controller so the client
 * and the server agree on what a cursor is, instead of each side patching it up its own way.
 */
export const pullQuery = z.object({
  cursor: z.coerce.number().int().nonnegative().default(0),
  branchId: uuidv7.optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(500),
});
export type PullQuery = z.infer<typeof pullQuery>;
