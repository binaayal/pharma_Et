import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { Test } from '@nestjs/testing';
import { getDataSourceToken } from '@nestjs/typeorm';
import * as argon2 from 'argon2';
import { DataSource } from 'typeorm';
import { uuidv7 } from 'uuidv7';
import { AppModule } from '../src/app.module';
import { PLATFORM_DATA_SOURCE } from '../src/common/db/scoped-db.service';

/**
 * Multi-tenant test harness (docs/05-qa §11).
 *
 * Every suite gets TWO tenants, each with branches, staff across all roles, products and
 * stock. This is not thoroughness for its own sake: a query missing its tenant predicate
 * behaves perfectly in a single-tenant fixture, so a single-tenant test cannot detect the
 * one defect class that is an automatic release blocker here.
 */

export interface SeededUser {
  id: string;
  username: string;
  role: 'owner' | 'branch_manager' | 'cashier';
  token: string;
}

export interface SeededTenant {
  id: string;
  code: string;
  branchIds: string[];
  productId: string;
  controlledProductId: string;
  batchIds: string[];
  users: Record<'owner' | 'manager' | 'cashier', SeededUser>;
}

export const TEST_PIN = '1234';
export const TEST_TERMINAL = '01930000-0000-7000-8000-0000000000e1';

/** A syntactically valid UUIDv7 with a caller-chosen tail, for readable fixtures. */
export function testUuid(tag: number): string {
  const hex = tag.toString(16).padStart(12, '0');
  return `01930000-0000-7000-8000-${hex}`;
}

export class TestHarness {
  app: INestApplication;
  private platform: DataSource;

  static async start(): Promise<TestHarness> {
    const harness = new TestHarness();
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    harness.app = moduleRef.createNestApplication();
    harness.app.setGlobalPrefix('api');
    await harness.app.init();
    harness.platform = harness.app.get<DataSource>(getDataSourceToken(PLATFORM_DATA_SOURCE));
    return harness;
  }

  async stop(): Promise<void> {
    await this.app.close();
  }

  /**
   * Wipes every table. Runs on the platform (owner) connection, because the application
   * role deliberately has no DELETE grant anywhere — nothing in this system is physically
   * deleted in production, and the grants say so.
   */
  async reset(): Promise<void> {
    await this.platform.query(`
      TRUNCATE oversell_event, applied_op, payment, sale_line, sale,
               goods_receipt_line, goods_receipt, stock_batch, product,
               user_branch, app_user, branch, tenant_change_seq, tenant
      RESTART IDENTITY CASCADE;
    `);
  }

  async seedTenant(code: string, productPriceSantim = 1500): Promise<SeededTenant> {
    const tenantId = uuidv7();
    const branchIds = [uuidv7(), uuidv7()];
    const productId = uuidv7();
    const controlledProductId = uuidv7();
    const batchIds = [uuidv7(), uuidv7()];
    const pinHash = await argon2.hash(TEST_PIN, { type: argon2.argon2id });

    await this.platform.transaction(async (em) => {
      /**
       * Allocates change sequences from `tenant_change_seq`, exactly as ChangeSeqService
       * does at runtime. A fixture that keeps its own counter drifts out of step with the
       * real one, and then a delta pull silently returns nothing because the rows it should
       * send carry sequence numbers below the cursor. Fixtures share the production
       * allocator so the test cannot pass against a world the server never produces.
       */
      const next = async (): Promise<number> => {
        const result = await em.query(
          `UPDATE tenant_change_seq SET value = value + 1 WHERE tenant_id = $1 RETURNING value`,
          [tenantId],
        );
        const rows = Array.isArray(result[0]) ? result[0] : result;
        return Number(rows[0].value);
      };

      await em.query(`INSERT INTO tenant (id, name, code) VALUES ($1, $2, $3)`, [
        tenantId,
        `${code} Pharmacy`,
        code,
      ]);
      await em.query(`INSERT INTO tenant_change_seq (tenant_id, value) VALUES ($1, 0)`, [tenantId]);

      for (const [index, branchId] of branchIds.entries()) {
        await em.query(
          `INSERT INTO branch (id, tenant_id, name, change_seq) VALUES ($1, $2, $3, $4)`,
          [branchId, tenantId, `${code} branch ${index + 1}`, await next()],
        );
      }

      const users: Array<[string, 'owner' | 'branch_manager' | 'cashier']> = [
        ['owner', 'owner'],
        ['manager', 'branch_manager'],
        ['cashier', 'cashier'],
      ];
      for (const [username, role] of users) {
        const id = uuidv7();
        await em.query(
          `INSERT INTO app_user (id, tenant_id, username, display_name, role, pin_hash, change_seq)
           VALUES ($1, $2, $3, $4, $5, $6, $7)`,
          [id, tenantId, username, `${code} ${username}`, role, pinHash, await next()],
        );
        if (role !== 'owner') {
          await em.query(
            `INSERT INTO user_branch (id, tenant_id, user_id, branch_id, change_seq)
             VALUES ($1, $2, $3, $4, $5)`,
            [uuidv7(), tenantId, id, branchIds[0], await next()],
          );
        }
      }

      await em.query(
        `INSERT INTO product (id, tenant_id, name, unit, is_controlled, current_price_santim, change_seq)
         VALUES ($1, $2, $3, 'tablet', false, $4, $5)`,
        [productId, tenantId, `${code} paracetamol`, productPriceSantim, await next()],
      );
      await em.query(
        `INSERT INTO product (id, tenant_id, name, unit, is_controlled, psychotropic_class, current_price_santim, change_seq)
         VALUES ($1, $2, $3, 'tablet', true, 'schedule-iv', $4, $5)`,
        [controlledProductId, tenantId, `${code} diazepam`, 4000, await next()],
      );

      // Two batches with different expiry dates so FEFO has a real choice (AC-3.2).
      const expiries = ['2027-06-30', '2026-11-30'];
      for (const [index, expiry] of expiries.entries()) {
        await em.query(
          `INSERT INTO stock_batch (id, tenant_id, branch_id, product_id, lot_no, expiry_date, qty_on_hand, change_seq)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
          [
            batchIds[index],
            tenantId,
            branchIds[0],
            productId,
            `LOT-${index + 1}`,
            expiry,
            10,
            await next(),
          ],
        );
      }
    });

    const tokens = {} as SeededTenant['users'];
    for (const username of ['owner', 'manager', 'cashier'] as const) {
      const response = await this.login(code, username);
      tokens[username] = {
        id: response.scope.userId,
        username,
        role: response.scope.role,
        token: response.accessToken,
      };
    }

    return {
      id: tenantId,
      code,
      branchIds,
      productId,
      controlledProductId,
      batchIds,
      users: tokens,
    };
  }

  async login(tenantCode: string, username: string) {
    const response = await request(this.app.getHttpServer())
      .post('/api/auth/login')
      .send({ tenantCode, username, secret: TEST_PIN, terminalId: TEST_TERMINAL })
      .expect(200);
    return response.body;
  }

  /** Direct access to the owner connection, for assertions that must see past RLS. */
  get platformDataSource(): DataSource {
    return this.platform;
  }

  /** The application's own (RLS-bound) connection, for proving the backstop works. */
  get appDataSource(): DataSource {
    return this.app.get<DataSource>(getDataSourceToken());
  }
}
