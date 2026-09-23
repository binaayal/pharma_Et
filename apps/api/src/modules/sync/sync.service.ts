import { Injectable, Logger } from '@nestjs/common';
import type {
  Ack,
  Operation,
  PullQuery,
  PullResponse,
  PushRequest,
  PushResponse,
} from '@pharmaet/contracts';
import { CONTRACT_VERSION } from '@pharmaet/contracts';
import type { EntityManager } from 'typeorm';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import type { TenantScope } from '../../common/db/tenant-scope';
import {
  AppUser,
  AppliedOp,
  Branch,
  GoodsReceipt,
  GoodsReceiptLine,
  Payment,
  Product,
  Sale,
  SaleLine,
  StockBatch,
  UserBranch,
} from '../../entities';
import { ChangeSeqService } from '../inventory/change-seq.service';
import { InventoryService } from '../inventory/inventory.service';

/**
 * The server half of the SyncService seam (ADR-005). This is a CONTROLLED ARTIFACT — see
 * docs/06-delivery-plan.md §7 before changing anything here.
 *
 * Three properties carry the whole design, and guardian G2 exists to prove them:
 *
 *   1. **Exactly once.** Idempotency is keyed on `op_id` in `applied_op`, not inferred from
 *      the data. A terminal that loses the connection mid-batch retries the whole batch; the
 *      already-applied half comes back `duplicate` rather than being applied twice.
 *
 *   2. **Per-operation isolation.** Each operation commits in its own transaction, so one
 *      rejected operation cannot roll back the twenty valid sales queued behind it. A push
 *      is a batch for transport efficiency, never an all-or-nothing unit.
 *
 *   3. **Ordering by `terminal_seq`.** Never by client timestamp — device clocks drift, and
 *      a receipt ordered after the sale that consumed its stock produces nonsense.
 *
 * There is no conflict resolution here, deliberately. V1 is single-writer (ADR-002), so
 * conflicts cannot arise, and speculative conflict code would be untested code sitting in
 * the most dangerous path in the system.
 */
@Injectable()
export class SyncService {
  private readonly logger = new Logger(SyncService.name);

  constructor(
    private readonly db: ScopedDbService,
    private readonly inventory: InventoryService,
    private readonly changeSeq: ChangeSeqService,
  ) {}

  async push(scope: TenantScope, request: PushRequest): Promise<PushResponse> {
    const ordered = [...request.operations].sort((a, b) => a.terminalSeq - b.terminalSeq);
    const acks: Ack[] = [];

    for (const operation of ordered) {
      acks.push(await this.applyOne(scope, operation));
    }

    const changeSeq = await this.db.runInScope(scope, (em) =>
      this.changeSeq.current(em, scope.tenantId),
    );

    return { contractVersion: CONTRACT_VERSION, acks, changeSeq };
  }

  private async applyOne(scope: TenantScope, operation: Operation): Promise<Ack> {
    // An operation claiming a different tenant than the token is not a validation slip; it
    // is an attempt to write across a tenant boundary. Reject it here, and note that RLS
    // would refuse the write anyway — the two layers are independent on purpose (ADR-003).
    if (operation.tenantId !== scope.tenantId) {
      return this.reject(operation, 'operation tenant does not match the authenticated tenant');
    }

    try {
      return await this.db.runInScope(scope, async (em) => {
        const already = await em
          .getRepository(AppliedOp)
          .findOne({ where: { tenantId: scope.tenantId, opId: operation.opId } });
        if (already) {
          return { opId: operation.opId, status: 'duplicate', serverVersion: null, reason: null };
        }

        switch (operation.entityType) {
          case 'sale':
            await this.applySale(em, scope, operation);
            break;
          case 'goods_receipt':
            await this.applyGoodsReceipt(em, scope, operation);
            break;
        }

        await em.getRepository(AppliedOp).insert({
          tenantId: scope.tenantId,
          opId: operation.opId,
          entityId: operation.entityId,
          entityType: operation.entityType,
          terminalId: operation.terminalId,
          terminalSeq: operation.terminalSeq,
        });

        return { opId: operation.opId, status: 'applied', serverVersion: 1, reason: null };
      });
    } catch (error) {
      // A rejected operation stays a first-class result: the client parks it in a
      // "needs attention" queue. We never drop a real transaction because we could not
      // apply it — losing it silently is the failure this system is built to prevent.
      const reason = error instanceof Error ? error.message : 'unknown error';
      this.logger.error(`op ${operation.opId} rejected: ${reason}`);
      return this.reject(operation, reason);
    }
  }

  private reject(operation: Operation, reason: string): Ack {
    return { opId: operation.opId, status: 'rejected', serverVersion: null, reason };
  }

  private async applySale(
    em: EntityManager,
    scope: TenantScope,
    operation: Extract<Operation, { entityType: 'sale' }>,
  ): Promise<void> {
    const { payload } = operation;
    const branchId = operation.branchId;
    if (!branchId) throw new Error('a sale must name its branch');

    await em.getRepository(Sale).insert({
      id: operation.entityId,
      tenantId: scope.tenantId,
      branchId,
      shiftId: payload.shiftId,
      cashierId: payload.cashierId,
      terminalId: operation.terminalId,
      totalSantim: payload.totalSantim,
      soldAt: new Date(payload.soldAt),
      changeSeq: 0,
      deletedAt: null,
    });

    for (const line of payload.lines) {
      await em.getRepository(SaleLine).insert({
        id: line.id,
        tenantId: scope.tenantId,
        saleId: operation.entityId,
        productId: line.productId,
        batchId: line.batchId,
        qty: line.qty,
        unitPriceSantim: line.unitPriceSantim,
        lineTotalSantim: line.lineTotalSantim,
        changeSeq: 0,
        deletedAt: null,
      });
    }

    for (const payment of payload.payments) {
      await em.getRepository(Payment).insert({
        id: payment.id,
        tenantId: scope.tenantId,
        saleId: operation.entityId,
        method: payment.method,
        amountSantim: payment.amountSantim,
        changeSeq: 0,
        deletedAt: null,
      });
    }

    await this.inventory.applySaleDecrements(
      em,
      scope.tenantId,
      payload.lines.map((line) => ({
        branchId,
        productId: line.productId,
        batchId: line.batchId,
        qty: line.qty,
        saleId: operation.entityId,
      })),
    );
  }

  private async applyGoodsReceipt(
    em: EntityManager,
    scope: TenantScope,
    operation: Extract<Operation, { entityType: 'goods_receipt' }>,
  ): Promise<void> {
    const { payload } = operation;
    const branchId = operation.branchId;
    if (!branchId) throw new Error('a goods receipt must name its branch');

    await em.getRepository(GoodsReceipt).insert({
      id: operation.entityId,
      tenantId: scope.tenantId,
      branchId,
      supplierName: payload.supplierName,
      receivedAt: new Date(payload.receivedAt),
      terminalId: operation.terminalId,
      changeSeq: 0,
      deletedAt: null,
    });

    for (const line of payload.lines) {
      await em.getRepository(GoodsReceiptLine).insert({
        id: line.id,
        tenantId: scope.tenantId,
        goodsReceiptId: operation.entityId,
        productId: line.productId,
        lotNo: line.lotNo,
        expiryDate: line.expiryDate,
        qty: line.qty,
        costSantim: line.costSantim,
        changeSeq: 0,
        deletedAt: null,
      });

      // The receipt line's id doubles as the batch id when the lot is new to this branch,
      // so the batch is addressable without a server round-trip (ADR-006).
      await this.inventory.applyReceipt(em, scope.tenantId, {
        branchId,
        productId: line.productId,
        lotNo: line.lotNo,
        expiryDate: line.expiryDate,
        qty: line.qty,
        batchId: line.id,
      });
    }
  }

  /**
   * Delta pull of reference data (docs/04 §7.2).
   *
   * Reference data flows server -> client only, while transactional data flows client ->
   * server via push. Keeping the two directions disjoint is what makes single-writer V1
   * conflict-free without any conflict-resolution code.
   */
  async pull(scope: TenantScope, query: PullQuery): Promise<PullResponse> {
    return this.db.runInScope(scope, async (em) => {
      const { cursor, limit } = query;

      const products = await em
        .getRepository(Product)
        .createQueryBuilder('p')
        .where('p.change_seq > :cursor', { cursor })
        .orderBy('p.change_seq', 'ASC')
        .limit(limit)
        .getMany();

      const branches = await em
        .getRepository(Branch)
        .createQueryBuilder('b')
        .where('b.change_seq > :cursor', { cursor })
        .orderBy('b.change_seq', 'ASC')
        .limit(limit)
        .getMany();

      const users = await em
        .getRepository(AppUser)
        .createQueryBuilder('u')
        .where('u.change_seq > :cursor', { cursor })
        .orderBy('u.change_seq', 'ASC')
        .limit(limit)
        .getMany();

      const userBranches = users.length
        ? await em
            .getRepository(UserBranch)
            .createQueryBuilder('ub')
            .where('ub.user_id IN (:...ids)', { ids: users.map((u) => u.id) })
            .getMany()
        : [];

      const stockQuery = em
        .getRepository(StockBatch)
        .createQueryBuilder('s')
        .where('s.change_seq > :cursor', { cursor });
      if (query.branchId) {
        stockQuery.andWhere('s.branch_id = :branchId', { branchId: query.branchId });
      }
      const stockBatches = await stockQuery.orderBy('s.change_seq', 'ASC').limit(limit).getMany();

      const pages = [products, branches, users, stockBatches];
      const maxSeq = Math.max(cursor, ...pages.flatMap((rows) => rows.map((r) => r.changeSeq)));

      return {
        contractVersion: CONTRACT_VERSION,
        cursor: maxSeq,
        // A full page may mean more rows remain; the client pulls again immediately rather
        // than waiting for the next sync window and running on half a catalog.
        hasMore: pages.some((rows) => rows.length === limit),
        products: products.map((p) => ({
          id: p.id,
          name: p.name,
          unit: p.unit,
          isControlled: p.isControlled,
          psychotropicClass: p.psychotropicClass,
          currentPriceSantim: p.currentPriceSantim,
          changeSeq: p.changeSeq,
          deletedAt: p.deletedAt?.toISOString() ?? null,
        })),
        branches: branches.map((b) => ({
          id: b.id,
          name: b.name,
          address: b.address,
          changeSeq: b.changeSeq,
          deletedAt: b.deletedAt?.toISOString() ?? null,
        })),
        users: users.map((u) => ({
          id: u.id,
          displayName: u.displayName,
          role: u.role,
          branchIds: userBranches.filter((ub) => ub.userId === u.id).map((ub) => ub.branchId),
          changeSeq: u.changeSeq,
          deletedAt: u.deletedAt?.toISOString() ?? null,
        })),
        stockBatches: stockBatches.map((s) => ({
          id: s.id,
          branchId: s.branchId,
          productId: s.productId,
          lotNo: s.lotNo,
          expiryDate: s.expiryDate,
          qtyOnHand: s.qtyOnHand,
          changeSeq: s.changeSeq,
          deletedAt: s.deletedAt?.toISOString() ?? null,
        })),
        serverTime: new Date().toISOString(),
      };
    });
  }
}
