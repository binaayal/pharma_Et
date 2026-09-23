/**
 * Three projects, because the docs' risk tiers are not a metaphor (docs/05-qa §3, §4):
 *
 *   unit        — pure domain logic, no I/O. Fast enough to run on every save.
 *   integration — real PostgreSQL. RLS, constraints and SET LOCAL scoping are the things
 *                 under test, and a mocked database exercises none of them.
 *   guardian    — the merge gate. The invariants whose failure is an S1. No override, and a
 *                 flaky guardian test is itself a blocking defect.
 */
const base = {
  transform: { '^.+\\.ts$': ['ts-jest', { tsconfig: '<rootDir>/tsconfig.json' }] },
  moduleFileExtensions: ['ts', 'js', 'json'],
  rootDir: '.',
  testEnvironment: 'node',
};
// Timeouts are set in test/setup-env.ts, not here: `testTimeout` is not a valid key inside
// a `projects` entry and Jest only warns about it, so a config that looks correct would
// silently leave the real-database suites on the 5s default.

module.exports = {
  projects: [
    { ...base, displayName: 'unit', testMatch: ['<rootDir>/test/unit/**/*.spec.ts'] },
    {
      ...base,
      displayName: 'integration',
      testMatch: ['<rootDir>/test/integration/**/*.spec.ts'],
      setupFilesAfterEnv: ['<rootDir>/test/setup-env.ts'],
      globalSetup: '<rootDir>/test/global-setup.ts',
    },
    {
      ...base,
      displayName: 'e2e',
      testMatch: ['<rootDir>/test/e2e/**/*.e2e-spec.ts'],
      setupFilesAfterEnv: ['<rootDir>/test/setup-env.ts'],
      globalSetup: '<rootDir>/test/global-setup.ts',
    },
    {
      ...base,
      displayName: 'perf',
      testMatch: ['<rootDir>/test/perf/**/*.perf-spec.ts'],
      setupFilesAfterEnv: ['<rootDir>/test/setup-env.ts'],
      globalSetup: '<rootDir>/test/global-setup.ts',
    },
    {
      ...base,
      displayName: 'guardian',
      testMatch: ['<rootDir>/test/guardian/**/*.spec.ts'],
      setupFilesAfterEnv: ['<rootDir>/test/setup-env.ts'],
      globalSetup: '<rootDir>/test/global-setup.ts',
    },
  ],
  collectCoverageFrom: ['src/**/*.ts', '!src/migrations/**', '!src/seed.ts'],
  coverageThreshold: {
    // Per-tier targets from docs/05-qa §3. A trend to watch, never the gate — the gate is
    // the guardian suites passing.
    global: { branches: 60, lines: 70 },
  },
};
