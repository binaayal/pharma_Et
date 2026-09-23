import { SetMetadata } from '@nestjs/common';
import type { UserRole } from '../../entities';

export const ROLES_KEY = 'roles';

/** Restricts a route to the given roles (FR-2 permission matrix). */
export const Roles = (...roles: UserRole[]) => SetMetadata(ROLES_KEY, roles);
