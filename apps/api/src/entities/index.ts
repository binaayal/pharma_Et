import { AppUser } from './app-user.entity';
import { Branch } from './branch.entity';
import { GoodsReceipt, GoodsReceiptLine } from './goods-receipt.entity';
import { Product } from './product.entity';
import { Payment, Sale, SaleLine } from './sale.entity';
import { PaymentProof, PlatformAdmin, Subscription } from './billing.entity';
import { DomainEvent } from './event.entity';
import { CashUp, Shift } from './shift.entity';
import { StockAdjustment } from './stock-adjustment.entity';
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
export * from './billing.entity';
export * from './event.entity';
export * from './shift.entity';
export * from './stock-adjustment.entity';
export * from './stock-batch.entity';
export * from './sync.entity';
export * from './tenant.entity';
export * from './user-branch.entity';

/**
 * The entity set as far as Phase 1 has built it.
 *
 * The `event` table carries both the general action audit log (Vision §2.1.1) and, on the
 * `controlled_stock` stream, the controlled-substance ledger — built ahead of A-1 and refused
 * while the switch is off (ADR-024). Its projection, `controlled_stock_view`, is maintained
 * with raw SQL in `modules/ledger/`. No retention rule exists: the store never deletes.
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
  StockAdjustment,
  DomainEvent,
  PlatformAdmin,
  Subscription,
  PaymentProof,
  GoodsReceipt,
  GoodsReceiptLine,
  AppliedOp,
  TenantChangeSeq,
  OversellEvent,
];
