import { BadRequestException, PipeTransform } from '@nestjs/common';
import type { ZodSchema } from 'zod';

/**
 * Validates a request body against the shared contract schema (ADR-010).
 *
 * The same Zod schema that generated the client's Dart types validates the request here, so
 * "the client and server agree about the envelope" is enforced at runtime rather than
 * assumed. A payload that would not have type-checked on the client cannot be accepted here.
 */
export class ZodValidationPipe<T> implements PipeTransform<unknown, T> {
  constructor(private readonly schema: ZodSchema<T>) {}

  transform(value: unknown): T {
    const result = this.schema.safeParse(value);
    if (!result.success) {
      throw new BadRequestException({
        message: 'contract validation failed',
        issues: result.error.issues.map((i) => ({
          path: i.path.join('.'),
          message: i.message,
        })),
      });
    }
    return result.data;
  }
}
