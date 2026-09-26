import type { ZodTypeAny } from 'zod';
import * as auth from '../auth.js';
import * as entities from '../entities.js';
import * as sync from '../sync.js';

/**
 * The registry of schemas that cross the wire, and therefore must exist on both sides.
 *
 * Adding a schema here is what makes it appear in the published JSON Schema and in the
 * generated Dart. If a type crosses the client/server boundary and is not in this map, it
 * is being hand-written somewhere — which is the drift ADR-010 forbids.
 */
export const CONTRACT_SCHEMAS: Record<string, ZodTypeAny> = {
  // Sync — the controlled artifact (docs/04 §7)
  Operation: sync.operation,
  Ack: sync.ack,
  PushRequest: sync.pushRequest,
  PushResponse: sync.pushResponse,
  PullResponse: sync.pullResponse,
  ProductRef: sync.productRef,
  BranchRef: sync.branchRef,
  UserRef: sync.userRef,
  StockBatchRef: sync.stockBatchRef,

  // Entity payloads
  SalePayload: entities.salePayload,
  SaleLinePayload: entities.saleLinePayload,
  PaymentPayload: entities.paymentPayload,
  GoodsReceiptPayload: entities.goodsReceiptPayload,
  GoodsReceiptLinePayload: entities.goodsReceiptLinePayload,
  ShiftPayload: entities.shiftPayload,
  CashUpPayload: entities.cashUpPayload,
  StockAdjustmentPayload: entities.stockAdjustmentPayload,
  PrescriptionPayload: entities.prescriptionPayload,
  ControlledDispensePayload: entities.controlledDispensePayload,
  ControlledAdjustmentPayload: entities.controlledAdjustmentPayload,

  // Auth
  LoginRequest: auth.loginRequest,
  LoginResponse: auth.loginResponse,
  RefreshRequest: auth.refreshRequest,
  AuthScope: auth.authScope,
};

// `RefreshResponse` is deliberately absent: it IS `LoginResponse`, and emitting a second
// Dart class with identical fields would let the two drift apart later for no reason. A
// refresh returns a whole new session — see the note on `refreshResponse` in `auth.ts`.
