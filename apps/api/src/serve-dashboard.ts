import { Logger } from '@nestjs/common';
import type { INestApplication } from '@nestjs/common';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import express from 'express';
import type { NextFunction, Request, Response } from 'express';

/**
 * Serves the web dashboard from the API process (docs/03-architecture.md §7).
 *
 * Three reasons this beats a separate static host, and the first is the one that bites:
 *
 *  - **One origin.** CORS stops existing for the console. A wrong `CORS_ORIGINS` is
 *    otherwise an outage that looks exactly like a working console talking to a broken
 *    backend — the browser blocks the request and the server logs nothing.
 *  - **One artifact.** The bundle and the API it calls are built and deployed together, so
 *    a console can never be live against a server it was not built for.
 *  - **One deploy target** to keep running.
 *
 * Written against Express directly rather than @nestjs/serve-static: that package pins a
 * `path-to-regexp` with a high-severity advisory and its current release requires NestJS 11.
 * What we need is twenty lines, and in a regulated system a dependency we do not need is a
 * dependency we do not have to patch.
 *
 * `express` is therefore a DIRECT dependency of this package, not a borrowed transitive one
 * from @nestjs/platform-express. pnpm's strict node_modules refuses an undeclared import
 * outright, which is the behaviour ADR-010 chose it for.
 *
 * It is pinned to the 4.x line on purpose: @nestjs/platform-express@10 runs on Express 4,
 * and declaring `express@5` here would install a SECOND copy — this middleware would then
 * come from a different Express than the app it is mounted on. That kind of mismatch does
 * not fail loudly; it produces subtly different `sendFile` and routing behaviour.
 */
export function serveDashboard(app: INestApplication): void {
  const bundle = join(__dirname, '..', 'public');

  // The bundle is optional. The image builds it in; a local `pnpm dev` has no public/ and
  // must still start rather than failing over a missing asset path.
  if (!existsSync(bundle)) {
    new Logger('dashboard').log('no bundle at public/ — serving the API only');
    return;
  }

  const index = join(bundle, 'index.html');

  app.use(
    express.static(bundle, {
      // index.html is served by the fallback below, so that one code path decides its
      // headers rather than two.
      index: false,
      setHeaders: (res, filePath) => {
        // Vite emits every content-hashed file into `assets/` and nothing else there, so
        // the directory IS the immutability contract — a far better signal than matching
        // the hash, which is base64url (`index-API4IJGH.js`), not the lowercase hex people
        // assume.
        if (/[\\/]assets[\\/]/.test(filePath)) {
          res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
        } else {
          res.setHeader('Cache-Control', 'no-cache');
        }
      },
    }),
  );

  // Single-page-app fallback: any unmatched GET that is not an API call returns index.html,
  // so a deep link or a refresh lands on the app instead of a 404.
  app.use((req: Request, res: Response, next: NextFunction) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') return next();

    // An unmatched /api route MUST keep 404ing. Falling through to index.html would answer
    // a bad API call with 200 and a page of HTML, which every client parses as a corrupt
    // response rather than as the error it is.
    if (req.path === '/api' || req.path.startsWith('/api/')) return next();

    // index.html carries the hashed asset names and is not itself hashed. Cache it and a
    // deploy never reaches anyone still holding the old copy.
    res.setHeader('Cache-Control', 'no-cache');
    res.sendFile(index, (error) => {
      if (error) next(error);
    });
  });

  new Logger('dashboard').log('serving the dashboard bundle from public/');
}
