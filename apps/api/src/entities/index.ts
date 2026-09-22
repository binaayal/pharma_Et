import { AppUser } from './app-user.entity';
import { Branch } from './branch.entity';
import { GoodsReceipt, GoodsReceiptLine } from './goods-receipt.entity';
import { Product } from './product.entity';
import { Payment, Sale, SaleLine } from './sale.entity';
import { StockBatch } from './stock-batch.entity';
import { AppliedOp, OversellEvent, TenantChangeSeq } from './sync.entity';
import { Tenant } from './tenant.entity';
import { UserBranch } from './user-branch.entity';

export * from './app-user.entity';
export * from './base.entity';
export * from './branch.entity';
export * from './goods-receipt.entity';
export * from './product.entity';
export * from './sale.entity';
export * from './stock-batch.entity';
export * from './sync.entity';
export * from './tenant.entity';
export * from './user-branch.entity';

/**
 * Phase 0 entity set — the walking skeleton (docs/04 §13).
 *
 * The controlled-substance `event` table, its projections, shifts, cash-up and
 * subscriptions are Phase 1/2 and are deliberately absent: ADR-004's ledger is not
 * something to half-build ahead of the A-1 compliance gate.
 */
export const ALL_ENTITIES = [
  Tenant,
  Branch,
  AppUser,
  UserBranch,
  Product,
  StockBatch,
  Sale,
  SaleLine,
  Payment,
  GoodsReceipt,
  GoodsReceiptLine,
  AppliedOp,
  TenantChangeSeq,
  OversellEvent,
];
