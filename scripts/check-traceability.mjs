#!/usr/bin/env node
/**
 * Traceability integrity (docs/05-qa §8, docs/06 §11).
 *
 * The RTM in `docs/02-srs.md` is the claim that every requirement has code and a test behind
 * it, and `06` §11 gates GA on that table being complete. A table like that decays quietly:
 * a file is renamed, a suite is split, an ADR is written and never indexed — and nothing
 * fails, because prose does not compile.
 *
 * This is the thing that fails. It does not judge whether a row's *status* is honest — no
 * script can — but it does prove that everything the table points at exists, which is the
 * half that rots on its own.
 */
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(repo, p), 'utf8');

/**
 * Where a citation may be rooted.
 *
 * The RTM writes paths the way an engineer says them out loud — `api/src/modules/sync/`,
 * `mobile/lib/data/local_db.dart` — rather than from the repository root. That is the right
 * trade for a document people read, so the checker accommodates it instead of demanding the
 * table get longer and less readable.
 */
const ROOTS = [
  '',
  'apps/',
  'apps/api/',
  'apps/api/src/',
  'apps/api/test/',
  'apps/mobile/',
  'apps/mobile/lib/',
  'apps/mobile/test/',
  'apps/dashboard/',
  'apps/dashboard/src/',
  'packages/',
  'packages/contracts/',
  'packages/contracts/src/',
  'docs/',
  'scripts/',
];

/** Migrations are cited by name; on disk they carry a timestamp prefix. */
function resolvesAsMigration(ref) {
  const cut = ref.lastIndexOf('/');
  if (cut < 0) return false;
  const [dir, name] = [ref.slice(0, cut), ref.slice(cut + 1)];
  for (const root of ROOTS) {
    const full = join(repo, root, dir);
    if (!existsSync(full)) continue;
    if (readdirSync(full).some((f) => f.includes(name))) return true;
  }
  return false;
}

function resolves(ref) {
  // Brace or glob shorthand (`mobile/lib/{sync,data/outbox.dart}`) stands for several real
  // paths. Expanding it properly is more machinery than the risk warrants, and the parts are
  // cited individually elsewhere in the table.
  if (/[{}*]/.test(ref)) return true;
  if (ROOTS.some((root) => existsSync(join(repo, root, ref)))) return true;
  return resolvesAsMigration(ref);
}

const failures = [];

// ---------------------------------------------------------------- 1. RTM citations
const srs = read('docs/02-srs.md').split('\n');
const rows = srs
  .map((line, i) => ({ line, n: i + 1 }))
  .filter(({ line }) => line.startsWith('| ') && line.split('|').length >= 5);

let cited = 0;
for (const { line, n } of rows) {
  for (const [, ref] of line.matchAll(/`([^`]+)`/g)) {
    if (!ref.includes('/') || ref.startsWith('http')) continue;
    cited += 1;
    if (!resolves(ref)) {
      failures.push(`docs/02-srs.md:${n} — RTM cites a path that does not exist: ${ref}`);
    }
  }
}

// ---------------------------------------------------------------- 2. Markdown links resolve
// Added after writing two ADR links in README.md from memory and getting both filenames
// wrong. Nothing would have caught them: the RTM check above reads `docs/02-srs.md` only, and
// a dead link in the file people read first is the worst place to have one — it is the
// document that tells somebody where everything else is.
let links = 0;
const linked = ['README.md', 'CONTRIBUTING.md', 'docs/README.md', 'docs/adr/README.md'];
for (const source of linked) {
  if (!existsSync(join(repo, source))) continue;
  const text = read(source);
  const base = dirname(source);
  for (const [, label, target] of text.matchAll(/\[([^\]]+)\]\(([^)]+)\)/g)) {
    if (/^(https?:|#|mailto:)/.test(target)) continue;
    const path = target.split('#')[0];
    if (!path) continue;
    links += 1;
    // Relative to the file that links it, the way a reader's click resolves it.
    if (!existsSync(join(repo, base, path))) {
      failures.push(`${source} links to something that does not exist: [${label}](${target})`);
    }
  }
}

// ---------------------------------------------------------------- 3. ADRs are indexed
// Two indexes list the ADRs, and both are maintained by hand. An ADR that is written but
// unlisted is one nobody will find at the moment they are about to violate it, which is the
// only moment it matters.
const adrFiles = readdirSync(join(repo, 'docs/adr'))
  .filter((f) => /^ADR-\d+.*\.md$/.test(f))
  .sort();
const adrIndex = read('docs/adr/README.md');
const docsIndex = read('docs/README.md');

for (const file of adrFiles) {
  if (!adrIndex.includes(file)) {
    failures.push(`docs/adr/README.md does not list ${file}`);
  }
  if (!docsIndex.includes(file)) {
    failures.push(`docs/README.md does not list ${file}`);
  }
}

// ---------------------------------------------------------------- 4. ADR references resolve
// A binding decision referred to by number must exist. `ADR-020` in a comment, with no such
// file, reads as authority that was never written down.
const numbers = new Set(adrFiles.map((f) => f.match(/^ADR-(\d+)/)[1]));
const sources = [
  'docs/02-srs.md',
  'docs/05-qa-and-test-strategy.md',
  'docs/06-delivery-plan.md',
  'docs/adr/README.md',
  'docs/README.md',
];
for (const source of sources) {
  const text = read(source);
  for (const [, n] of text.matchAll(/ADR-(\d{3})/g)) {
    if (!numbers.has(n)) {
      failures.push(`${source} refers to ADR-${n}, which does not exist`);
    }
  }
}

// ----------------------------------------------------------------------------- report
if (failures.length > 0) {
  console.error('traceability check failed:\n');
  for (const f of failures) console.error(`  ${f}`);
  console.error(
    `\ndocs/05-qa §8 and docs/06 §11 make the RTM the evidence that every requirement has\n` +
      `code and a test behind it. A citation that points at nothing is not evidence.\n`,
  );
  process.exit(1);
}

console.log(
  `traceability ok — ${cited} RTM citations resolve, ${links} markdown links land, ` +
    `${adrFiles.length} ADRs indexed in both tables`,
);
