#!/usr/bin/env node
/**
 * The GA gate, made mechanical (docs/06 §11).
 *
 * §11 is a go/no-go checklist, and a checklist in prose is a promise that somebody will read
 * it honestly on the day they most want to ship. This makes it a thing that refuses.
 *
 * **The checklist in `06-delivery-plan.md` IS the manifest.** There is no second file to keep
 * in step with it — a second file is just a place for the two to disagree. A box is met when
 * it is ticked AND its line cites evidence, and every cited path must exist. Ticking a box
 * without naming what makes it true fails here, which is the point: "we are ready" should
 * cost somebody the effort of saying why.
 *
 *   node scripts/release-readiness.mjs                  # the GA gate: exit 1 unless ready
 *   node scripts/release-readiness.mjs --evidence-only  # CI: exit 1 only on a false claim
 *   node scripts/release-readiness.mjs --report         # report only, always exit 0
 *
 * The three modes exist because "not ready yet" and "this claim is untrue" are different
 * facts. An outstanding gate is the normal condition of a project before GA and must not
 * turn every build red; a ticked box citing a file that does not exist is a defect on the
 * day it is written, and CI should say so then rather than on release day.
 */
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..');
const reportOnly = process.argv.includes('--report');
const evidenceOnly = process.argv.includes('--evidence-only');

const plan = readFileSync(join(repo, 'docs/06-delivery-plan.md'), 'utf8');

// §11 only. Bounded by the next heading so a checkbox elsewhere in the plan cannot be
// mistaken for a release gate.
const section = plan.split('## 11. Launch-readiness checklist')[1];
if (!section) {
  console.error('could not find §11 in docs/06-delivery-plan.md — has it been renamed?');
  process.exit(1);
}
const body = section.split('\n## ')[0];

const items = [...body.matchAll(/^- \[( |x)\] (.+)$/gm)].map(([, mark, text]) => ({
  met: mark === 'x',
  text: text.trim(),
}));

if (items.length === 0) {
  console.error('§11 has no checklist items — that cannot be right');
  process.exit(1);
}

/** Paths cited in a line, resolved the same way the traceability check resolves them. */
const ROOTS = ['', 'docs/', 'apps/', 'scripts/', '.github/workflows/'];
function citedPaths(text) {
  return [...text.matchAll(/`([^`]+)`/g)]
    .map(([, ref]) => ref)
    .filter((ref) => ref.includes('/') || ref.endsWith('.md') || ref.endsWith('.yml'));
}
function resolves(ref) {
  if (/[{}*]/.test(ref)) return true;
  const bare = ref.replace(/\s+§.*$/, '').trim();
  for (const root of ROOTS) {
    const full = join(repo, root, bare);
    if (existsSync(full)) return true;
    // A directory reference, or a name with a timestamp prefix on disk.
    const parent = join(repo, root, dirname(bare));
    if (existsSync(parent)) {
      const name = bare.split('/').pop();
      if (readdirSync(parent).some((f) => f.includes(name))) return true;
    }
  }
  return false;
}

const problems = [];
const outstanding = [];

for (const item of items) {
  const label = item.text.replace(/\s+—\s+\*.*$/, '').replace(/\*\*/g, '');
  if (!item.met) {
    outstanding.push(label);
    continue;
  }
  const cited = citedPaths(item.text);
  if (cited.length === 0) {
    // A ticked box with nothing behind it is the failure mode this exists to stop.
    problems.push(`ticked with no evidence cited: ${label}`);
    continue;
  }
  for (const ref of cited) {
    if (!resolves(ref)) {
      problems.push(`cites a path that does not exist (${ref}): ${label}`);
    }
  }
}

const met = items.length - outstanding.length;
console.log(`\nLaunch readiness (docs/06 §11) — ${met}/${items.length} met\n`);
for (const item of items) {
  const label = item.text.replace(/\s+—\s+\*.*$/, '').replace(/\*\*/g, '');
  console.log(`  ${item.met ? '[x]' : '[ ]'} ${label}`);
}

if (problems.length > 0) {
  console.log('\nProblems with the checklist itself:');
  for (const p of problems) console.log(`  ! ${p}`);
}

if (outstanding.length === 0 && problems.length === 0) {
  console.log('\nAll launch-readiness gates are met and evidenced.\n');
  process.exit(0);
}

if (evidenceOnly) {
  // Outstanding gates are expected before GA and say nothing about the checklist's honesty.
  // Only a claim that cannot be substantiated fails here.
  if (problems.length > 0) {
    console.error('\nA launch-readiness claim is not substantiated. Fix the claim or the evidence.\n');
    process.exit(1);
  }
  console.log(`\n${outstanding.length} gate(s) outstanding, every claim evidenced.\n`);
  process.exit(0);
}

console.log(
  `\n${outstanding.length} gate(s) outstanding. GA is blocked by docs/06 §11.\n` +
    `These are not engineering effort in the ordinary sense — a restore drill needs hosted\n` +
    `infrastructure, the device matrix needs a handset, the pilot needs a pharmacy, and A-1\n` +
    `needs the EFDA retail directive. None of them can be cleared by writing code.\n`,
);

process.exit(reportOnly ? 0 : 1);
