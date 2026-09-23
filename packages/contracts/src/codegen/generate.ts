import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CONTRACT_VERSION } from '../version.js';
import { emitDart } from './dart.js';
import { buildContractJsonSchema } from './json-schema.js';

/**
 * `pnpm gen:contracts`
 *
 * Zod (the source) -> JSON Schema (the published artifact, used by contract tests)
 *                  -> Dart (the mobile client's types).
 *
 * Output is committed. CI runs this and fails on any diff, so a contract change can never
 * land on one side only (ADR-010, docs/05-qa §6).
 */

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '../../../..');

const targets = {
  jsonSchema: resolve(repoRoot, 'packages/contracts/generated/contract.schema.json'),
  dart: resolve(repoRoot, 'apps/mobile/lib/contracts/contracts.dart'),
};

const schema = buildContractJsonSchema();
const dart = emitDart(schema, CONTRACT_VERSION);

for (const [label, path] of Object.entries(targets)) {
  mkdirSync(dirname(path), { recursive: true });
  const content = label === 'jsonSchema' ? `${JSON.stringify(schema, null, 2)}\n` : dart;
  writeFileSync(path, content, 'utf8');
  console.log(`  ✓ ${label.padEnd(10)} ${path.replace(`${repoRoot}/`, '')}`);
}

// Deliberately NOT run through `dart format`.
//
// The freshness gate compares these bytes, so anything that influences them has to be
// pinned — and `dart format` changes its output between SDK versions. Routing generated
// code through it makes the gate fail whenever a developer's Dart differs from CI's, for a
// reason that has nothing to do with the contract. The emitter's own output is the
// canonical form instead: reproducible from Node alone, with no Dart SDK in the loop.
// The file is excluded from the analyzer and from the repository's format check.

console.log(`\ncontract v${CONTRACT_VERSION} generated.`);
