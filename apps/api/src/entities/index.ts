import { AppUser } from './app-user.entity';
import { Branch } from './branch.entity';
import { GoodsReceipt, GoodsReceiptLine } from './goods-receipt.entity';
import { Product } from './product.entity';
import { Payment, Sale, SaleLine } from './sale.entity';
import { CashUp, Shift } from './shift.entity';
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
export * from './shift.entity';
export * from './stock-batch.entity';
export * from './sync.entity';
export * from './tenant.entity';
export * from './user-branch.entity';

/**
 * The entity set as far as Phase 1 has built it.
 *
 * The controlled-substance `event` table, its projections, and subscriptions remain absent:
 * ADR-004's ledger is not something to half-build ahead of the A-1 compliance gate, and
 * nothing here should make it look closer than it is.
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
  Shift,
  CashUp,
  GoodsReceipt,
  GoodsReceiptLine,
  AppliedOp,
  TenantChangeSeq,
  OversellEvent,
];
