import { SetMetadata } from '@nestjs/common';
import type { Capability } from '@pharmaet/contracts';

export const CAPABILITY_KEY = 'capability';

/**
 * Requires a capability from the FR-2 matrix.
 *
 * Preferred over `@Roles(...)`: a role list has to be re-derived at every handler and drifts
 * from the SRS one endpoint at a time, whereas a capability is looked up in the one table
 * that the matrix tests exercise.
 */
export const RequireCapability = (capability: Capability) =>
  SetMetadata(CAPABILITY_KEY, capability);
