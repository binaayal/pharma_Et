import { Injectable, Logger } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { uuidv7 } from 'uuidv7';
import { OversellEvent, StockBatch } from '../../entities';
import { ChangeSeqService } from './change-seq.service';
import { TelemetryService } from '../../common/observability/telemetry.service';

export interface StockDecrement {
  branchId: string;
  productId: string;
  batchId: string | null;
  qty: number;
  saleId: string;
}

@Injectable()
export class InventoryService {
  private readonly logger = new Logger(InventoryService.name);

  constructor(
    private readonly changeSeq: ChangeSeqService,
    private readonly telemetry: TelemetryService,
  ) {}

  /**
   * Applies a sale's effect on standard-drug stock.
   *
   * The rule that surprises people: **the stock level never vetoes anything here.** The sale
   * already happened — it was rung up on a terminal that may have been offline for days and
   * could not have known this count (BR-3.2, ADR-002). Our job on the server is to record
   * the decrement faithfully and, if it drives the batch negative, to make that visible.
   *
   * An oversell is a physical-world discrepancy that somebody needs to go and reconcile, so
   * it is written as a row (guardian G5, NFR-7). Refusing the sale would be worse than
   * useless: it would reject a transaction whose money is already in the till.
   */
  async applySaleDecrements(
    em: EntityManager,
    tenantId: string,
    decrements: StockDecrement[],
  ): Promise<void> {
    for (const decrement of decrements) {
      const batch = decrement.batchId
        ? await em.getRepository(StockBatch).findOne({ where: { id: decrement.batchId } })
        : await this.selectFefoBatch(em, decrement.branchId, decrement.productId);

      if (!batch) {
        // The terminal sold a product with no batch on the server — a product created on one
        // terminal and sold before its receipt synced, typically. Record the oversell against
        // no batch rather than dropping the decrement on the floor.
        await this.recordOversell(em, tenantId, decrement, null, -decrement.qty);
        continue;
      }

      const resulting = batch.qtyOnHand - decrement.qty;
      batch.qtyOnHand = resulting;
      batch.changeSeq = await this.changeSeq.next(em, tenantId);
      await em.getRepository(StockBatch).save(batch);

      if (resulting < 0) {
        await this.recordOversell(em, tenantId, decrement, batch.id, resulting);
      }
    }
  }

  /**
   * FEFO — first to expire, first out (AC-3.2).
   *
   * Expiry order, not receipt order: a pharmacy's loss is stock that expires on the shelf,
   * and dispensing the longest-dated box first is how that happens. Batches already expired
   * are excluded; dispensing those requires an explicit authorised override (E-4.2).
   */
  async selectFefoBatch(
    em: EntityManager,
    branchId: string,
    productId: string,
  ): Promise<StockBatch | null> {
    return em
      .getRepository(StockBatch)
      .createQueryBuilder('b')
      .where('b.branch_id = :branchId', { branchId })
      .andWhere('b.product_id = :productId', { productId })
      .andWhere('b.deleted_at IS NULL')
      .andWhere('b.expiry_date >= CURRENT_DATE')
      .orderBy('b.expiry_date', 'ASC')
      .addOrderBy('b.qty_on_hand', 'DESC')
      .getOne();
  }

  private async recordOversell(
    em: EntityManager,
    tenantId: string,
    decrement: StockDecrement,
    batchId: string | null,
    resultingQty: number,
  ): Promise<void> {
    // NFR-7. Structured rather than a warn string, because this is a rate to watch and not
    // an incident to read: oversell is *expected* to be non-zero here (BR-3.2 records rather
    // than prevents), so the signal is the shape of the curve. The runbook's §4.5 turns on
    // telling a stock problem in one branch apart from a sync problem across many.
    this.telemetry.oversell({
      tenantId,
      branchId: decrement.branchId,
      productId: decrement.productId,
      resultingQty,
    });
    await em.getRepository(OversellEvent).insert({
      id: uuidv7(),
      tenantId,
      branchId: decrement.branchId,
      productId: decrement.productId,
      batchId,
      saleId: decrement.saleId,
      resultingQty,
    });
  }

  /** Goods receipt: stock in. Creates the batch if this lot is new to the branch. */
  async applyReceipt(
    em: EntityManager,
    tenantId: string,
    line: {
      branchId: string;
      productId: string;
      lotNo: string;
      expiryDate: string;
      qty: number;
      batchId: string;
    },
  ): Promise<void> {
    const repo = em.getRepository(StockBatch);
    const existing = await repo.findOne({
      where: {
        branchId: line.branchId,
        productId: line.productId,
        lotNo: line.lotNo,
        deletedAt: null as never,
      },
    });

    const changeSeq = await this.changeSeq.next(em, tenantId);

    if (existing) {
      existing.qtyOnHand += line.qty;
      existing.changeSeq = changeSeq;
      await repo.save(existing);
      return;
    }

    await repo.insert({
      id: line.batchId,
      tenantId,
      branchId: line.branchId,
      productId: line.productId,
      lotNo: line.lotNo,
      expiryDate: line.expiryDate,
      qtyOnHand: line.qty,
      changeSeq,
      deletedAt: null,
    });
  }
}
