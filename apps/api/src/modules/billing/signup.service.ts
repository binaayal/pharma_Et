import {
  BadRequestException,
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { uuidv7 } from 'uuidv7';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import { BillingService } from './billing.service';

export interface SignupRequestView {
  id: string;
  pharmacyName: string;
  ownerName: string;
  phone: string;
  city: string;
  branchBand: '1' | '2-3' | '4+';
  status: 'pending' | 'approved' | 'rejected';
  submittedAt: string;
  decidedAt: string | null;
  decisionReason: string | null;
  tenantId: string | null;
}

/**
 * The onboarding gate (ADR-022).
 *
 * Anyone may ask; only a person at the platform may say yes. Approval opens the tenant and
 * its owner account in the same transaction that closes the request, so there is never a
 * tenant without a decision behind it, nor an approved request without a tenant.
 */
@Injectable()
export class SignupService {
  constructor(
    private readonly db: ScopedDbService,
    private readonly billing: BillingService,
  ) {}

  async submit(input: {
    pharmacyName: string;
    ownerName: string;
    phone: string;
    city: string;
    branchBand: '1' | '2-3' | '4+';
  }): Promise<{ id: string; status: 'pending' }> {
    const phone = normalisePhone(input.phone);
    return this.db.runAsPlatform('record a sign-up request', async (em) => {
      const open = await em.query(
        `SELECT 1 FROM signup_request WHERE phone = $1 AND status = 'pending'`,
        [phone],
      );
      // Said plainly rather than hidden: the caller already knows the number is theirs.
      if (open.length) throw new ConflictException('a request from this number is already waiting');

      const id = uuidv7();
      await em.query(
        `INSERT INTO signup_request (id, pharmacy_name, owner_name, phone, city, branch_band)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        [
          id,
          input.pharmacyName.trim(),
          input.ownerName.trim(),
          phone,
          input.city.trim(),
          input.branchBand,
        ],
      );
      return { id, status: 'pending' as const };
    });
  }

  async list(status?: 'pending' | 'approved' | 'rejected'): Promise<SignupRequestView[]> {
    const rows = await this.db.runAsPlatform('list sign-up requests', (em) =>
      em.query(
        `SELECT id, pharmacy_name AS "pharmacyName", owner_name AS "ownerName", phone, city,
                branch_band AS "branchBand", status, submitted_at AS "submittedAt",
                decided_at AS "decidedAt", decision_reason AS "decisionReason",
                tenant_id_created AS "tenantId"
           FROM signup_request
          WHERE ($1::text IS NULL OR status = $1)
          ORDER BY submitted_at ${status === 'pending' ? 'ASC' : 'DESC'}
          LIMIT 200`,
        [status ?? null],
      ),
    );
    return rows.map((r: Record<string, unknown>) => ({
      ...r,
      submittedAt: new Date(r.submittedAt as string).toISOString(),
      decidedAt: r.decidedAt ? new Date(r.decidedAt as string).toISOString() : null,
    })) as SignupRequestView[];
  }

  async decide(
    adminId: string,
    id: string,
    decision:
      | { accept: true; code: string; ownerUsername: string; ownerPin: string }
      | { accept: false; reason: string },
  ) {
    return this.db.runAsPlatform(`decide sign-up request ${id}`, async (em) => {
      const [request] = await em.query(
        `SELECT id, pharmacy_name AS "pharmacyName", owner_name AS "ownerName", status
           FROM signup_request WHERE id = $1 FOR UPDATE`,
        [id],
      );
      if (!request) throw new NotFoundException('no such request');
      if (request.status !== 'pending') {
        throw new BadRequestException(`this request was already ${request.status}`);
      }

      if (!decision.accept) {
        await em.query(
          `UPDATE signup_request
              SET status = 'rejected', decided_at = now(), decided_by = $2, decision_reason = $3
            WHERE id = $1`,
          [id, adminId, decision.reason.trim()],
        );
        return { id, status: 'rejected' as const };
      }

      const opened = await this.billing.createTenantIn(em, adminId, {
        name: request.pharmacyName,
        code: decision.code,
        ownerUsername: decision.ownerUsername,
        ownerDisplayName: request.ownerName,
        ownerPin: decision.ownerPin,
      });
      await em.query(
        `UPDATE signup_request
            SET status = 'approved', decided_at = now(), decided_by = $2, tenant_id_created = $3
          WHERE id = $1`,
        [id, adminId, opened.tenantId],
      );
      return { id, status: 'approved' as const, ...opened };
    });
  }
}

/** `0912 345 678`, `+251 91 234 5678` and `251912345678` are one phone. */
export function normalisePhone(raw: string): string {
  const digits = raw.replace(/[^\d]/g, '');
  if (digits.startsWith('251') && digits.length === 12) return `+${digits}`;
  if (digits.startsWith('0') && digits.length === 10) return `+251${digits.slice(1)}`;
  if (digits.length === 9 && /^[79]/.test(digits)) return `+251${digits}`;
  throw new BadRequestException('enter an Ethiopian phone number, e.g. +251 91 234 5678');
}
