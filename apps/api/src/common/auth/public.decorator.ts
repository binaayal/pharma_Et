import { SetMetadata } from '@nestjs/common';

export const IS_PUBLIC_KEY = 'isPublic';

/**
 * Opts a route out of authentication. Use sparingly and obviously — login and health are
 * the whole list.
 */
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);
