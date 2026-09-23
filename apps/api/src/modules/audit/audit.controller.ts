import { BadRequestException, Controller, Get, Query } from '@nestjs/common';
import { RequireCapability } from '../../common/auth/capability.decorator';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import type { TenantScope } from '../../common/db/tenant-scope';
import { AUDIT_EVENT_TYPES, AuditService } from './audit.service';

/**
 * The audit trail (FR-6 generalized, Vision §2.1.1).
 *
 * Gated on `settings.configure`, which the FR-2 matrix grants to the owner alone. That is
 * deliberate and slightly stricter than it might look: the audit log names who did what, and
 * a branch manager reading the record of their own staff is a different thing from an owner
 * reviewing the business. If that proves too tight in the field it is one cell of the matrix
 * to change — which is exactly the kind of decision the matrix exists to make visible.
 */
@Controller('audit')
export class AuditController {
  constructor(
    private readonly db: ScopedDbService,
    private readonly audit: AuditService,
  ) {}

  @Get()
  @RequireCapability('settings.configure')
  async list(
    @CurrentScope() scope: TenantScope,
    @Query('streamId') streamId?: string,
    @Query('actorId') actorId?: string,
    @Query('eventType') eventType?: string,
    @Query('limit') limit?: string,
  ) {
    if (eventType && !(AUDIT_EVENT_TYPES as readonly string[]).includes(eventType)) {
      // A typo silently returning nothing would read as "nobody did that", which is the
      // worst possible answer from an audit log.
      throw new BadRequestException(
        `unknown event type "${eventType}"; known types: ${AUDIT_EVENT_TYPES.join(', ')}`,
      );
    }
    const take = limit === undefined ? 100 : Number(limit);
    if (!Number.isInteger(take) || take < 1 || take > 1000) {
      throw new BadRequestException('limit must be a whole number between 1 and 1000');
    }

    return this.db.runInScope(scope, (em) =>
      this.audit.list(em, { streamId, actorId, eventType, limit: take }),
    );
  }

  /**
   * Continuity check for one stream.
   *
   * "The log has not been tampered with" is the only claim an audit log really makes, and a
   * gap is indistinguishable from a deletion. The database forbids DELETE outright, so a gap
   * would mean something stranger — and worth knowing before an auditor finds it.
   */
  @Get('verify')
  @RequireCapability('settings.configure')
  async verify(@CurrentScope() scope: TenantScope, @Query('streamId') streamId: string) {
    if (!streamId) throw new BadRequestException('streamId is required');
    return this.db.runInScope(scope, (em) => this.audit.verifyContinuity(em, streamId));
  }
}
