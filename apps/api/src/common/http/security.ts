import type { NestExpressApplication } from '@nestjs/platform-express';
import type { NextFunction, Request, Response } from 'express';

/**
 * The HTTP security baseline (NFR-4.3, docs/engineering/security.md), applied by `main.ts`
 * AND by the test harness — so the headers, the proxy trust and the limits a guardian
 * suite sees are the ones production serves, not a second copy that drifts.
 */
export interface HttpSecurityOptions {
  nodeEnv: string;
  /**
   * How many reverse proxies sit in front of the app (Fly's edge is one). Without it every
   * request appears to come from the proxy, and the per-address login throttle (ADR-017)
   * becomes ONE counter shared by every pharmacy in the country: twenty wrong PINs anywhere
   * would stop everyone signing in for fifteen minutes.
   */
  trustProxy: number;
  rateLimit: boolean;
}

export function applyHttpSecurity(app: NestExpressApplication, options: HttpSecurityOptions) {
  const production = options.nodeEnv === 'production' || options.nodeEnv === 'staging';

  app.set('trust proxy', options.trustProxy);
  // "Express" in every response tells a scanner which advisories to try first.
  app.disable('x-powered-by');

  // HTTPS only. Fly already refuses plain HTTP at its edge (`force_https`); this is the same
  // rule said by the app, so a second host or a misconfigured proxy cannot quietly serve
  // tokens and PINs in clear text.
  if (production) {
    app.use((req: Request, res: Response, next: NextFunction) => {
      if (req.secure || req.headers['x-forwarded-proto'] === 'https') return next();
      if (req.path === '/api/health') return next(); // the platform's own plain-HTTP probe
      if (req.method === 'GET' || req.method === 'HEAD') {
        return res.redirect(308, `https://${req.headers.host}${req.originalUrl}`);
      }
      // Never redirect a POST: the body has already crossed the wire in clear, and a
      // redirect would teach the client that doing so works.
      res.status(403).json({ statusCode: 403, message: 'HTTPS is required' });
    });
  }

  app.use((req: Request, res: Response, next: NextFunction) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    res.setHeader('Cross-Origin-Resource-Policy', 'same-origin');
    res.setHeader('X-DNS-Prefetch-Control', 'off');
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=()');
    // The console is a static bundle from this origin talking to this origin. Nothing else
    // may run, load, frame it or be posted to — so an injected string has nowhere to go.
    res.setHeader(
      'Content-Security-Policy',
      [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self'",
        "img-src 'self' data: blob:",
        "connect-src 'self'",
        "font-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'",
      ].join('; '),
    );
    if (production) {
      // Only in production: asserting HSTS from localhost poisons the browser's cache for
      // every other project on the machine.
      res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    }
    // API answers are per-user data. No proxy or browser cache may keep one; routes that
    // are genuinely cacheable (the dashboard's hashed assets) are not under /api.
    if (req.path.startsWith('/api/')) res.setHeader('Cache-Control', 'no-store');
    next();
  });

  if (options.rateLimit) app.use(rateLimiter(RATE_LIMITS));
}

export interface RateRule {
  /** Matched against `METHOD /path`. The first matching rule applies. */
  match: RegExp;
  limit: number;
  windowMs: number;
  name: string;
}

/**
 * Per-address request budgets.
 *
 * Generous where a real pharmacy lives — a terminal syncs every 30 s, and a shop may put
 * several terminals behind one NAT — and tight where only an attacker needs volume. These
 * sit IN FRONT of the credential throttle (ADR-017), not in place of it: that one counts
 * failures per identity and survives a restart; this one caps raw volume per address and
 * protects the argon2 verifier, which is deliberately expensive, from being made to run
 * thousands of times a minute.
 */
export const RATE_LIMITS: RateRule[] = [
  { name: 'signup', match: /^POST \/api\/signup-requests\/?$/, limit: 5, windowMs: 3_600_000 },
  {
    name: 'login',
    match: /^POST \/api\/(auth\/login|platform\/login)\/?$/,
    limit: 30,
    windowMs: 60_000,
  },
  { name: 'refresh', match: /^POST \/api\/auth\/refresh\/?$/, limit: 60, windowMs: 60_000 },
  { name: 'api', match: /^[A-Z]+ \/api\//, limit: 600, windowMs: 60_000 },
];

/**
 * A fixed-window counter per address and rule, in process memory.
 *
 * In memory on purpose: it needs no Redis, and across N instances the effective budget is
 * N × the limit — still bounded, which is the property that matters. Old windows are swept
 * as they are passed, so the map is bounded by the addresses seen in one window.
 */
export function rateLimiter(rules: RateRule[], now: () => number = Date.now) {
  const windows = new Map<string, { start: number; count: number }>();
  let lastSweep = now();

  return (req: Request, res: Response, next: NextFunction) => {
    const key = `${req.method} ${req.path}`;
    const rule = rules.find((r) => r.match.test(key));
    if (!rule) return next();

    const t = now();
    if (t - lastSweep > 60_000) {
      for (const [k, w] of windows) {
        const ruleFor = rules.find((r) => k.startsWith(`${r.name}|`));
        if (!ruleFor || t - w.start >= ruleFor.windowMs) windows.delete(k);
      }
      lastSweep = t;
    }

    const id = `${rule.name}|${req.ip ?? 'unknown'}`;
    let window = windows.get(id);
    if (!window || t - window.start >= rule.windowMs) {
      window = { start: t, count: 0 };
      windows.set(id, window);
    }
    window.count++;

    const remaining = Math.max(0, rule.limit - window.count);
    res.setHeader('RateLimit-Limit', String(rule.limit));
    res.setHeader('RateLimit-Remaining', String(remaining));
    if (window.count > rule.limit) {
      const retryAfter = Math.ceil((window.start + rule.windowMs - t) / 1000);
      res.setHeader('Retry-After', String(retryAfter));
      res.status(429).json({
        statusCode: 429,
        error: 'Too many requests',
        message: `Too many requests. Try again in ${retryAfter} seconds.`,
        retryAfterSeconds: retryAfter,
      });
      return;
    }
    next();
  };
}
