import { execFileSync } from 'node:child_process';
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

// Run the generated Dart through `dart format` so that the emitter's output and what a
// developer gets from `dart format .` are the same bytes. Without this, anyone formatting
// the repository dirties a generated file and the codegen-freshness gate fails for a
// reason that has nothing to do with the contract.
try {
  execFileSync('dart', ['format', targets.dart], { stdio: 'pipe' });
  console.log('  ✓ formatted   dart format');
} catch {
  // The Dart SDK is not always present (a backend-only CI job, for instance). The output is
  // still valid Dart; it just may not match `dart format` byte for byte.
  console.log('  · dart SDK not found — skipping format of the generated Dart');
}

console.log(`\ncontract v${CONTRACT_VERSION} generated.`);
