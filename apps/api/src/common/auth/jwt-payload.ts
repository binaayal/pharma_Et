import type { UserRole } from '../../entities';

/** Claims carried in the access token; the source of every request's TenantScope. */
export interface JwtPayload {
  sub: string;
  tid: string;
  role: UserRole;
  branches: string[];
  terminal: string;
}
