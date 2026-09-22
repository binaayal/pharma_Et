import { z } from 'zod';
import { zodToJsonSchema } from 'zod-to-json-schema';
import { CONTRACT_VERSION } from '../version.js';
import { CONTRACT_SCHEMAS } from './schemas.js';

export type JsonSchema = Record<string, any>;

/**
 * Emits the whole contract as one JSON Schema document with every wire type under
 * `definitions`. This artifact is what contract tests validate against, and what the Dart
 * emitter reads — so client and server are provably describing the same shapes.
 */
export function buildContractJsonSchema(): JsonSchema {
  const emitted = zodToJsonSchema(z.object({}).describe('PharmaEt contract root'), {
    name: '__root__',
    definitions: CONTRACT_SCHEMAS,
    $refStrategy: 'root',
  }) as JsonSchema;

  // The wrapper exists only to make zod-to-json-schema emit every registered schema under
  // `definitions`; it is not part of the contract, so it does not survive into the artifact.
  const { __root__: _wrapper, ...definitions } = emitted.definitions ?? {};

  const root: JsonSchema = { definitions };

  return {
    $schema: 'http://json-schema.org/draft-07/schema#',
    title: 'PharmaEt sync & API contract',
    description:
      'Generated from packages/contracts/src by `pnpm gen:contracts`. Do not hand-edit. ' +
      'This is a controlled artifact — see docs/06-delivery-plan.md §7.',
    contractVersion: CONTRACT_VERSION,
    ...root,
  };
}
