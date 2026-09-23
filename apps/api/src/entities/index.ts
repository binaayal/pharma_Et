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
 * The `event` table is present — it carries the general action audit log, which Vision
 * §2.1.1 folds into V1 as product capability rather than compliance. What remains absent is
 * the regulated subset: no `controlled.*` event type, no projection, no retention rule.
 * ADR-015 draws that line and explains why it is where it is.
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
