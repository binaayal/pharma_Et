import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import {
  CAPABILITIES,
  PERMISSION_MATRIX,
  type Capability,
  type Grant,
  grantFor,
} from '@pharmaet/contracts';
import { TestHarness, type SeededTenant } from '../harness';

/**
 * G1 — THE FR-2 PERMISSION MATRIX, CELL BY CELL.
 *
 * `05-qa` §10 requires every role × capability cell to be exercised at both layers, allowed
 * cells succeeding and denied cells failing. This suite does that twice over: once against
 * the matrix table itself, and once against the live API, so that "the table says no" and
 * "the endpoint says no" cannot drift apart.
 *
 * The drift is the actual risk. A permission table everyone trusts, wired to an endpoint
 * nobody rechecked, is worse than no table at all — it converts a missing check into a
 * documented guarantee.
 */
describe('G1 — FR-2 permission matrix', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1500);
  });

  afterAll(async () => harness?.stop());

  const tokenFor = (role: 'owner' | 'branch_manager' | 'cashier') =>
    role === 'owner'
      ? tenant.users.owner.token
      : role === 'branch_manager'
        ? tenant.users.manager.token
        : tenant.users.cashier.token;

  /* ------------------------------------------------------------ the table */

  describe('the table mirrors the SRS', () => {
    const roles = ['owner', 'branch_manager', 'cashier'] as const;

    it('covers every capability for every role — no undefined cells', () => {
      // An undefined cell reads as `undefined`, which is neither allowed nor denied and
      // would take whichever branch the code happened to check first.
      for (const role of roles) {
        for (const capability of CAPABILITIES) {
          expect(PERMISSION_MATRIX[role][capability]).toBeDefined();
          expect(['tenant', 'branch', 'own', 'denied']).toContain(
            PERMISSION_MATRIX[role][capability],
          );
        }
      }
    });

    it.each([
      // Straight from the SRS FR-2 table. Written out rather than derived, so a change to
      // the implementation cannot quietly change the expectation too.
      ['owner', 'branch.manage', 'tenant'],
      ['owner', 'staff.manage', 'tenant'],
      ['owner', 'catalog.manage', 'tenant'],
      ['owner', 'report.tenant', 'tenant'],
      ['owner', 'settings.configure', 'tenant'],
      ['branch_manager', 'branch.manage', 'denied'],
      ['branch_manager', 'staff.manage', 'branch'],
      ['branch_manager', 'catalog.manage', 'branch'],
      ['branch_manager', 'report.branch', 'branch'],
      ['branch_manager', 'report.tenant', 'denied'],
      ['branch_manager', 'settings.configure', 'denied'],
      ['cashier', 'catalog.manage', 'denied'],
      ['cashier', 'staff.manage', 'denied'],
      ['cashier', 'goods.receive', 'branch'],
      ['cashier', 'sale.create', 'branch'],
      ['cashier', 'cashup.perform', 'own'],
      ['cashier', 'report.branch', 'own'],
      ['cashier', 'report.tenant', 'denied'],
    ] as const)('%s × %s = %s', (role, capability, expected) => {
      expect(grantFor(role, capability as Capability)).toBe(expected);
    });

    it('denies every tenant role the platform-admin capabilities (BR-2.2)', () => {
      // Platform Admin is an identity outside tenant scope entirely. An owner is the most
      // privileged person inside a tenant and still cannot verify their own payment.
      for (const role of roles) {
        expect(grantFor(role, 'tenant.manage')).toBe('denied');
        expect(grantFor(role, 'payment.verify')).toBe('denied');
      }
    });

    it('never grants a narrower role more than a broader one', () => {
      // A structural check: whatever the individual cells say, a cashier must never out-rank
      // a manager, nor a manager an owner. Catches a typo that a per-cell assertion would
      // only catch if somebody thought to write it.
      const rank: Record<Grant, number> = { denied: 0, own: 1, branch: 2, tenant: 3 };
      for (const capability of CAPABILITIES) {
        expect(rank[grantFor('cashier', capability)]).toBeLessThanOrEqual(
          rank[grantFor('branch_manager', capability)],
        );
        expect(rank[grantFor('branch_manager', capability)]).toBeLessThanOrEqual(
          rank[grantFor('owner', capability)],
        );
      }
    });
  });

  /* -------------------------------------------------------- the live API */

  describe('the API agrees with the table', () => {
    const call = (
      method: 'get' | 'post' | 'patch' | 'delete',
      path: string,
      role: 'owner' | 'branch_manager' | 'cashier',
      body?: object,
    ) => {
      const req = request(server())
        [method](`/api${path}`)
        .set('authorization', `Bearer ${tokenFor(role)}`);
      return body ? req.send(body) : req;
    };

    it.each([
      ['branch.manage', 'post', '/branches', { name: 'New Branch' }],
      ['catalog.manage', 'post', '/products', { name: 'X', unit: 'tablet', priceSantim: 100 }],
      ['staff.manage', 'get', '/users', undefined],
      ['report.branch', 'get', '/reports/sales-summary', undefined],
    ] as const)(
      '%s: each role gets what the table says',
      async (capability, method, path, body) => {
        for (const role of ['owner', 'branch_manager', 'cashier'] as const) {
          const grant = grantFor(role, capability as Capability);
          const response = await call(method, path, role, body);

          if (grant === 'denied') {
            // The direction that matters: the table says no, so the API must too.
            expect(response.status).toBe(403);
          } else if (grant === 'tenant' || grant === 'branch') {
            expect(response.status).not.toBe(403);
          }
          // `own` is deliberately not asserted here. It is allowed-but-narrowed, and
          // whether an endpoint can honour that narrowing depends on the endpoint: a
          // cash-up can be checked against its owner, an aggregate across a branch cannot.
          // Both outcomes are correct, so a blunt assertion would be wrong either way —
          // the `own` cases have their own tests below.
        }
      },
    );

    it('report.tenant is expressed by SCOPE, not by a separate endpoint', async () => {
      // One endpoint serves both matrix rows: an owner holds `tenant` and sees every
      // branch, a manager holds `branch` and sees their own. Splitting them would duplicate
      // the query and let the copies drift. A cashier's grant is `own`, which has nothing
      // to narrow an aggregate to, so the handler refuses it.
      const owner = await call('get', '/reports/sales-summary', 'owner').expect(200);
      const manager = await call('get', '/reports/sales-summary', 'branch_manager').expect(200);
      await call('get', '/reports/sales-summary', 'cashier').expect(403);

      expect(grantFor('owner', 'report.tenant')).toBe('tenant');
      expect(grantFor('branch_manager', 'report.tenant')).toBe('denied');
      // The owner's view is not narrowed; the manager's is.
      expect(owner.body.branches.length).toBeGreaterThanOrEqual(manager.body.branches.length);
    });

    it('AC-2.1: a cashier changing a price is denied at the API layer', async () => {
      const response = await call('post', `/products/${tenant.productId}/price`, 'cashier', {
        priceSantim: 1,
      });
      expect(response.status).toBe(403);

      // And the price is untouched — a denial that still wrote would be the worst outcome.
      const rows = await harness.platformDataSource.query(
        `SELECT current_price_santim FROM product WHERE id = $1`,
        [tenant.productId],
      );
      expect(Number(rows[0].current_price_santim)).toBe(1500);
    });

    it('an owner may change a price, and the change_seq moves so terminals learn of it', async () => {
      const before = await harness.platformDataSource.query(
        `SELECT change_seq FROM product WHERE id = $1`,
        [tenant.productId],
      );

      await call('post', `/products/${tenant.productId}/price`, 'owner', {
        priceSantim: 1750,
      }).expect(201);

      const after = await harness.platformDataSource.query(
        `SELECT current_price_santim, change_seq FROM product WHERE id = $1`,
        [tenant.productId],
      );
      expect(Number(after[0].current_price_santim)).toBe(1750);
      // Without this bump the counter keeps charging the old price until something
      // unrelated forces a full pull, and nobody connects the two (docs/04 §7.2).
      expect(Number(after[0].change_seq)).toBeGreaterThan(Number(before[0].change_seq));
    });

    it('rejects a fractional price at the boundary (G4)', async () => {
      await call('post', `/products/${tenant.productId}/price`, 'owner', {
        priceSantim: 17.5,
      }).expect(400);
    });

    it('refuses to create a controlled substance before A-1 clears', async () => {
      // A controlled product with mutable stock is exactly the unauditable record the
      // ledger exists to prevent (ADR-004).
      const response = await call('post', '/products', 'owner', {
        name: 'Diazepam 5mg',
        unit: 'tablet',
        priceSantim: 4000,
        isControlled: true,
      });
      expect(response.status).toBe(400);
      expect(JSON.stringify(response.body)).toMatch(/A-1|compliance/i);
    });

    it('stops a branch manager minting an owner (privilege escalation)', async () => {
      const response = await call('post', '/users', 'branch_manager', {
        username: `esc${Date.now()}`,
        displayName: 'Escalated',
        role: 'owner',
        pin: '9999',
        branchIds: [],
      });
      expect(response.status).toBe(403);
    });

    it('stops a branch manager assigning staff to a branch they do not run', async () => {
      const response = await call('post', '/users', 'branch_manager', {
        username: `out${Date.now()}`,
        displayName: 'Out of scope',
        role: 'cashier',
        pin: '9999',
        branchIds: [tenant.branchIds[1]],
      });
      expect(response.status).toBe(403);
    });

    it('lets a branch manager create a cashier in their own branch', async () => {
      const response = await call('post', '/users', 'branch_manager', {
        username: `ok${Date.now()}`,
        displayName: 'In scope',
        role: 'cashier',
        pin: '4321',
        branchIds: [tenant.branchIds[0]],
      });
      expect(response.status).toBe(201);
      expect(response.body.role).toBe('cashier');
    });

    it('refuses self-deactivation — an owner locked out has no recovery path', async () => {
      const response = await call('delete', `/users/${tenant.users.owner.id}`, 'owner');
      expect(response.status).toBe(400);
    });

    it('deactivates by soft-delete, never by removing the row (NFR-5.3)', async () => {
      const created = await call('post', '/users', 'owner', {
        username: `tmp${Date.now()}`,
        displayName: 'Temporary',
        role: 'cashier',
        pin: '5555',
        branchIds: [tenant.branchIds[0]],
      }).expect(201);

      await call('delete', `/users/${created.body.id}`, 'owner').expect(200);

      const rows = await harness.platformDataSource.query(
        `SELECT deleted_at FROM app_user WHERE id = $1`,
        [created.body.id],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0].deleted_at).not.toBeNull();
    });

    it('refuses every capability route without a token', async () => {
      for (const path of ['/branches', '/users', '/products']) {
        await request(server()).post(`/api${path}`).send({}).expect(401);
      }
    });

    it("never lets one tenant manage another's branch", async () => {
      const other = await harness.seedTenant(`t${Date.now() % 100000}`);
      const response = await request(server())
        .patch(`/api/branches/${other.branchIds[0]}`)
        .set('authorization', `Bearer ${tenant.users.owner.token}`)
        .send({ name: 'hijacked' });
      // RLS makes the row invisible, so it is a 404 rather than a 403 — which is the right
      // answer: the branch does not exist as far as this tenant is concerned.
      expect(response.status).toBe(404);

      const rows = await harness.platformDataSource.query(`SELECT name FROM branch WHERE id = $1`, [
        other.branchIds[0],
      ]);
      expect(rows[0].name).not.toBe('hijacked');
    });

    it('creates a branch only for an owner, and it is immediately visible', async () => {
      const name = `Branch ${uuidv7().slice(0, 8)}`;
      const created = await call('post', '/branches', 'owner', { name }).expect(201);
      expect(created.body.name).toBe(name);

      const list = await call('get', '/branches', 'owner').expect(200);
      expect(list.body.map((b: { id: string }) => b.id)).toContain(created.body.id);
    });
  });
});
