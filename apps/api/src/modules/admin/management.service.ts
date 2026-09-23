import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import * as argon2 from 'argon2';
import { uuidv7 } from 'uuidv7';
import type { Grant } from '@pharmaet/contracts';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import type { TenantScope } from '../../common/db/tenant-scope';
import { AppUser, Branch, Product, UserBranch, type UserRole } from '../../entities';
import { AuditService } from '../audit/audit.service';
import { ChangeSeqService } from '../inventory/change-seq.service';

/**
 * Tenant administration: branches, staff, catalog and pricing (FR-1, FR-2, FR-3).
 *
 * Every write here bumps the tenant's `change_seq`, which is not bookkeeping — it is how a
 * terminal learns about the change at all. A price edited without bumping it is a price
 * the counter keeps charging until something unrelated forces a full pull, and nobody
 * would connect the two (docs/04 §7.2).
 */
@Injectable()
export class ManagementService {
  constructor(
    private readonly db: ScopedDbService,
    private readonly changeSeq: ChangeSeqService,
    private readonly audit: AuditService,
  ) {}

  /**
   * A `branch` grant reaches only the branches the actor is assigned to.
   *
   * Called on every write that names a branch. The guard established *that* the role may
   * act; only the data can establish *where*, and skipping this is how a branch manager
   * ends up editing another branch's staff.
   */
  private assertBranchInScope(scope: TenantScope, grant: Grant, branchId: string): void {
    if (grant === 'tenant') return;
    if (!scope.branchIds.includes(branchId)) {
      throw new ForbiddenException('that branch is outside your scope');
    }
  }

  /* ----------------------------------------------------------------- branches */

  async listBranches(scope: TenantScope): Promise<Branch[]> {
    return this.db.runInScope(scope, (em) =>
      em
        .getRepository(Branch)
        .find({ where: { deletedAt: null as never }, order: { name: 'ASC' } }),
    );
  }

  async createBranch(scope: TenantScope, input: { name: string; address?: string }) {
    return this.db.runInScope(scope, async (em) => {
      const branch = em.getRepository(Branch).create({
        id: uuidv7(),
        tenantId: scope.tenantId,
        name: input.name.trim(),
        address: input.address?.trim() ?? null,
        changeSeq: await this.changeSeq.next(em, scope.tenantId),
        deletedAt: null,
      });
      await em.getRepository(Branch).insert(branch);
      // Inside the same transaction as the change itself. An audit record written
      // afterwards, best-effort, is missing precisely the entries somebody wanted missing.
      await this.audit.record(em, scope, {
        type: 'audit.branch_created',
        streamId: branch.id,
        branchId: branch.id,
        payload: { name: branch.name, address: branch.address },
      });
      return branch;
    });
  }

  async updateBranch(
    scope: TenantScope,
    branchId: string,
    input: { name?: string; address?: string },
  ) {
    return this.db.runInScope(scope, async (em) => {
      const repo = em.getRepository(Branch);
      const branch = await repo.findOne({ where: { id: branchId } });
      if (!branch) throw new NotFoundException('branch not found');

      const before = { name: branch.name, address: branch.address };
      if (input.name !== undefined) branch.name = input.name.trim();
      if (input.address !== undefined) branch.address = input.address.trim() || null;
      branch.changeSeq = await this.changeSeq.next(em, scope.tenantId);
      const saved = await repo.save(branch);

      // Both sides recorded. "The name changed" is not an audit entry; "from X to Y" is.
      await this.audit.record(em, scope, {
        type: 'audit.branch_updated',
        streamId: branch.id,
        branchId: branch.id,
        payload: { before, after: { name: saved.name, address: saved.address } },
      });
      return saved;
    });
  }

  /* -------------------------------------------------------------------- staff */

  async listUsers(scope: TenantScope, grant: Grant) {
    return this.db.runInScope(scope, async (em) => {
      const users = await em
        .getRepository(AppUser)
        .find({ where: { deletedAt: null as never }, order: { username: 'ASC' } });
      const assignments = await em.getRepository(UserBranch).find();

      const withBranches = users.map((u) => ({
        id: u.id,
        username: u.username,
        displayName: u.displayName,
        role: u.role,
        branchIds: assignments.filter((a) => a.userId === u.id).map((a) => a.branchId),
      }));

      if (grant === 'tenant') return withBranches;
      // A branch manager sees the staff of their own branches. Owners have no assignment
      // rows at all (they are all-branch by role), so they are visible to nobody below
      // tenant grant — which is correct: a manager has no business editing the owner.
      return withBranches.filter((u) => u.branchIds.some((b) => scope.branchIds.includes(b)));
    });
  }

  async createUser(
    scope: TenantScope,
    grant: Grant,
    input: {
      username: string;
      displayName: string;
      role: UserRole;
      pin: string;
      branchIds: string[];
    },
  ) {
    if (input.role === 'owner' && grant !== 'tenant') {
      // Otherwise a branch manager could mint an owner and escalate straight past the
      // matrix. Privilege escalation via user creation is the oldest bug in this class.
      throw new ForbiddenException('only an owner may create another owner');
    }
    if (input.role !== 'owner' && input.branchIds.length === 0) {
      throw new BadRequestException('a branch manager or cashier must be assigned a branch');
    }
    for (const branchId of input.branchIds) {
      this.assertBranchInScope(scope, grant, branchId);
    }

    return this.db.runInScope(scope, async (em) => {
      const branches = await em.getRepository(Branch).findByIds(input.branchIds);
      if (branches.length !== input.branchIds.length) {
        throw new BadRequestException('one or more branches do not exist in this tenant');
      }

      const id = uuidv7();
      await em.getRepository(AppUser).insert({
        id,
        tenantId: scope.tenantId,
        username: input.username.trim().toLowerCase(),
        displayName: input.displayName.trim(),
        role: input.role,
        // Argon2id, never the PIN itself — on the server or on the device (NFR-4.2).
        pinHash: await argon2.hash(input.pin, { type: argon2.argon2id }),
        passwordHash: null,
        changeSeq: await this.changeSeq.next(em, scope.tenantId),
        deletedAt: null,
      });

      for (const branchId of input.branchIds) {
        await em.getRepository(UserBranch).insert({
          id: uuidv7(),
          tenantId: scope.tenantId,
          userId: id,
          branchId,
          changeSeq: await this.changeSeq.next(em, scope.tenantId),
          deletedAt: null,
        });
      }

      await this.audit.record(em, scope, {
        type: 'audit.user_created',
        streamId: id,
        payload: {
          username: input.username,
          role: input.role,
          branchIds: input.branchIds,
          // Never the PIN, and never its hash. An audit log that records credentials turns
          // a read of the log into a compromise of every account it mentions.
        },
      });

      return { id, username: input.username, role: input.role, branchIds: input.branchIds };
    });
  }

  /**
   * Deactivates a user (soft-delete — nothing is ever physically removed, NFR-5.3).
   *
   * Refuses self-deactivation: an owner locking themselves out of their own tenant has no
   * recovery path that does not involve us.
   */
  async deactivateUser(scope: TenantScope, grant: Grant, userId: string) {
    if (userId === scope.userId) {
      throw new BadRequestException('you cannot deactivate your own account');
    }

    return this.db.runInScope(scope, async (em) => {
      const repo = em.getRepository(AppUser);
      const user = await repo.findOne({ where: { id: userId } });
      if (!user) throw new NotFoundException('user not found');

      if (grant !== 'tenant') {
        const assignments = await em.getRepository(UserBranch).find({ where: { userId } });
        const shared = assignments.some((a) => scope.branchIds.includes(a.branchId));
        if (!shared || user.role === 'owner') {
          throw new ForbiddenException('that user is outside your scope');
        }
      }

      user.deletedAt = new Date();
      user.changeSeq = await this.changeSeq.next(em, scope.tenantId);
      await repo.save(user);

      await this.audit.record(em, scope, {
        type: 'audit.user_deactivated',
        streamId: user.id,
        payload: { username: user.username, role: user.role },
      });
      return { id: user.id, deactivated: true };
    });
  }

  /* ------------------------------------------------------------------ catalog */

  async listProducts(scope: TenantScope) {
    return this.db.runInScope(scope, (em) =>
      em
        .getRepository(Product)
        .find({ where: { deletedAt: null as never }, order: { name: 'ASC' } }),
    );
  }

  async createProduct(
    scope: TenantScope,
    input: { name: string; unit: string; priceSantim: number; isControlled?: boolean },
  ) {
    if (!Number.isInteger(input.priceSantim) || input.priceSantim < 0) {
      // Money is an integer count of santim, refused at the boundary (docs/04 §3, G4).
      throw new BadRequestException('priceSantim must be a non-negative whole number of santim');
    }
    if (input.isControlled) {
      // Creating one would imply the ledger exists. It does not, and will not until A-1 is
      // verified (ADR-004, docs/06 §2) — a controlled product with mutable stock would be
      // exactly the unauditable record the ledger exists to prevent.
      throw new BadRequestException(
        'controlled substances cannot be created until the compliance phase (A-1) clears',
      );
    }

    return this.db.runInScope(scope, async (em) => {
      const id = uuidv7();
      await em.getRepository(Product).insert({
        id,
        tenantId: scope.tenantId,
        name: input.name.trim(),
        unit: input.unit.trim(),
        isControlled: false,
        psychotropicClass: null,
        currentPriceSantim: input.priceSantim,
        changeSeq: await this.changeSeq.next(em, scope.tenantId),
        deletedAt: null,
      });
      await this.audit.record(em, scope, {
        type: 'audit.product_created',
        streamId: id,
        payload: { name: input.name, unit: input.unit, priceSantim: input.priceSantim },
      });

      return { id, name: input.name, priceSantim: input.priceSantim };
    });
  }

  /**
   * Changes a price (AC-2.1's subject).
   *
   * The bumped `change_seq` is what carries the new price to every terminal on its next
   * pull. Without it the counter keeps charging yesterday's price, and the discrepancy
   * surfaces days later as a cash variance nobody can explain.
   */
  async setPrice(scope: TenantScope, productId: string, priceSantim: number) {
    if (!Number.isInteger(priceSantim) || priceSantim < 0) {
      throw new BadRequestException('priceSantim must be a non-negative whole number of santim');
    }

    return this.db.runInScope(scope, async (em) => {
      const repo = em.getRepository(Product);
      const product = await repo.findOne({ where: { id: productId } });
      if (!product) throw new NotFoundException('product not found');

      const previous = product.currentPriceSantim;
      product.currentPriceSantim = priceSantim;
      product.changeSeq = await this.changeSeq.next(em, scope.tenantId);
      await repo.save(product);

      // The entry Vision §2.1.1 is really about: a price changed at 11pm by somebody who
      // should not have is a finding an owner wants, controlled substance or not.
      await this.audit.record(em, scope, {
        type: 'audit.price_changed',
        streamId: product.id,
        payload: {
          productName: product.name,
          previousPriceSantim: previous,
          priceSantim,
          deltaSantim: priceSantim - previous,
        },
      });

      return { id: product.id, previousPriceSantim: previous, priceSantim };
    });
  }
}
