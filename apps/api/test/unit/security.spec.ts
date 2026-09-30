import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import type { NextFunction, Request, Response } from 'express';
import { rateLimiter, RATE_LIMITS } from '../../src/common/http/security';
import { neutraliseFormula } from '../../src/modules/ledger/ledger.service';
import { ProofStorageService } from '../../src/modules/billing/proof-storage.service';

/** The pure halves of the security baseline (docs/engineering/security.md). */
describe('security baseline — pure parts', () => {
  describe('rate limiter', () => {
    function drive(limiter: ReturnType<typeof rateLimiter>, path: string, ip = '1.2.3.4') {
      let status = 200;
      const headers: Record<string, string> = {};
      const res = {
        setHeader: (k: string, v: string) => (headers[k] = v),
        status(code: number) {
          status = code;
          return this;
        },
        json: () => undefined,
      } as unknown as Response;
      let passed = false;
      limiter(
        { method: 'POST', path, ip } as Request,
        res,
        (() => (passed = true)) as NextFunction,
      );
      return { status, passed, headers };
    }

    it('allows the budget, then answers 429 with Retry-After', () => {
      let t = 0;
      const limiter = rateLimiter(RATE_LIMITS, () => t);
      for (let i = 0; i < 30; i++) expect(drive(limiter, '/api/auth/login').passed).toBe(true);
      const refused = drive(limiter, '/api/auth/login');
      expect(refused.status).toBe(429);
      expect(Number(refused.headers['Retry-After'])).toBeGreaterThan(0);

      t += 60_000; // the window rolls over
      expect(drive(limiter, '/api/auth/login').passed).toBe(true);
    });

    it('counts each address separately', () => {
      const limiter = rateLimiter(RATE_LIMITS, () => 0);
      for (let i = 0; i < 5; i++) drive(limiter, '/api/signup-requests', '10.0.0.1');
      expect(drive(limiter, '/api/signup-requests', '10.0.0.1').status).toBe(429);
      expect(drive(limiter, '/api/signup-requests', '10.0.0.2').passed).toBe(true);
    });

    it('leaves a terminal syncing every 30 seconds nowhere near its budget', () => {
      // A shop with five terminals behind one NAT, each pushing and pulling twice a minute.
      const limiter = rateLimiter(RATE_LIMITS, () => 0);
      for (let i = 0; i < 5 * 2 * 2; i++) {
        expect(drive(limiter, '/api/sync/push').passed).toBe(true);
      }
    });
  });

  describe('CSV formula injection', () => {
    it.each(['=HYPERLINK("http://x")', '+1', '-2+3', '@SUM(A1)', '\tcmd', '\rcmd'])(
      'neutralises %j',
      (text) => expect(neutraliseFormula(text)).toBe(`'${text}`),
    );

    it('leaves numbers — negative ones included — as numbers', () => {
      expect(neutraliseFormula(-5)).toBe('-5');
      expect(neutraliseFormula('Dr. Abebe')).toBe('Dr. Abebe');
      expect(neutraliseFormula(null)).toBe('');
    });
  });

  describe('payment screenshots at rest', () => {
    const key = Buffer.alloc(32, 7).toString('base64');
    const storage = (k?: string) => new ProofStorageService({ get: () => k } as never);
    const png = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex');

    it('are not the image on disk, and read back exactly', () => {
      const sealed = storage(key).seal(png);
      expect(sealed.includes(png)).toBe(false);
      expect(storage(key).open(sealed)).toEqual(png);
    });

    it('refuse to open if a byte was altered on disk', () => {
      const sealed = storage(key).seal(png);
      sealed[sealed.length - 1] ^= 1;
      expect(() => storage(key).open(sealed)).toThrow();
    });

    it('still read a file written before encryption existed', () => {
      expect(storage(key).open(png)).toEqual(png);
    });
  });

  describe('parameterised SQL', () => {
    // Every runtime query binds its values ($1, $2…). A `${…}` inside a query string is how
    // that stops being true, one convenient edit at a time. Migrations are exempt: they
    // interpolate operator configuration (the app role's name), never request data.
    function files(dir: string): string[] {
      return readdirSync(dir).flatMap((name) => {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) return name === 'migrations' ? [] : files(path);
        return path.endsWith('.ts') ? [path] : [];
      });
    }

    it('serves no Server-Sent Events — the premise of the one OSV exception', () => {
      // osv-scanner.toml ignores GHSA-36xv-jgw5-4q75 (NestJS SSE newline injection) because
      // nothing here uses SSE. Adding an @Sse route makes that exception false; this fails
      // first, so the upgrade to NestJS 11 happens before the endpoint ships.
      const users = files(join(__dirname, '../../src')).filter((file) =>
        /@Sse\(/.test(readFileSync(file, 'utf8')),
      );
      expect(users).toEqual([]);
    });

    it('no query string interpolates a value', () => {
      const offenders: string[] = [];
      for (const file of files(join(__dirname, '../../src'))) {
        const text = readFileSync(file, 'utf8');
        for (const match of text.matchAll(/\.query(?:<[^>]*>)?\(\s*`([^`]*)`/g)) {
          const interpolations = [...match[1].matchAll(/\$\{([^}]*)\}/g)].map((m) => m[1]);
          // The one sanctioned shape: a fragment chosen from constants in the same function
          // (e.g. `${filter}` built from literal SQL with its own $n placeholders).
          const unsafe = interpolations.filter((name) => !SANCTIONED.has(name.trim()));
          if (unsafe.length) offenders.push(`${file}: ${unsafe.join(', ')}`);
        }
      }
      expect(offenders).toEqual([]);
    });
  });
});

/**
 * Interpolations reviewed and known to be SQL assembled from literals, never from input.
 * Adding to this list is a review decision, which is the point of having it.
 */
const SANCTIONED = new Set([
  'filter', // ledger.service: `AND v.branch_id = ANY($n::uuid[])`
  'where', // login-throttle.service: two constant predicates
  'branchFilter', // sales-summary / stock-report: `AND … = ANY($n::uuid[])`
  "status === 'pending' ? 'ASC' : 'DESC'", // signup.service: one of two keywords
]);
