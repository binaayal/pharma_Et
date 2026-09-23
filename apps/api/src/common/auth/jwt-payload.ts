import type { UserRole } from '../../entities';

/** Claims carried in the access token; the source of every request's TenantScope. */
export interface JwtPayload {
  sub: string;
  tid: string;
  role: UserRole;
  branches: string[];
  terminal: string;

  /**
   * What kind of token this is.
   *
   * Absent on tokens issued before this claim existed, and treated as an access token for
   * that reason. Every other value — `refresh`, `platform` — names a token that must not
   * authenticate an API call, and `JwtAuthGuard` refuses them.
   *
   * This exists because a signature check answers "did we issue this?", which is not the
   * question. The question is "did we issue this *for this purpose*", and only a claim can
   * answer it.
   */
  typ?: 'access' | 'refresh';
}
