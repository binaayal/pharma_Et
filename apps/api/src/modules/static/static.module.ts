import { Module } from '@nestjs/common';
import { ServeStaticModule } from '@nestjs/serve-static';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Serves the web dashboard from the API process.
 *
 * This is what `docs/03-architecture.md` §7 describes — "web dashboard served as static
 * assets + the same NestJS API" — and it is worth doing for reasons beyond matching the
 * diagram:
 *
 *  - **One origin.** The console and the API share a scheme, host and port, so CORS is not
 *    part of the picture at all. A misconfigured `CORS_ORIGINS` is otherwise an outage that
 *    looks exactly like a working console talking to a broken backend.
 *  - **One artifact.** The bundle and the API it talks to are built and deployed together,
 *    so a dashboard can never be live against a server it was not built for.
 *  - **One deploy target**, which matters when one person keeps it running.
 *
 * The bundle is optional. The image builds it in; a local `pnpm dev` has no `public/`
 * directory and must still start rather than failing over a missing asset path.
 */
const bundle = join(__dirname, '..', '..', '..', 'public');

@Module({
  imports: existsSync(bundle)
    ? [
        ServeStaticModule.forRoot({
          rootPath: bundle,
          // The API owns /api; everything else is the single-page app. Without this the
          // static handler would answer an unmatched /api route with index.html, turning a
          // 404 into a 200 full of HTML — which a client parses as a corrupt response.
          exclude: ['/api/(.*)'],
          serveStaticOptions: {
            setHeaders: (res, filePath) => {
              // Vite emits every content-hashed file into `assets/` and nothing else there,
              // so the directory IS the immutability contract — and a far more reliable
              // signal than pattern-matching the hash, which is base64url (`index-API4IJGH.js`),
              // not the lowercase hex people assume.
              //
              // index.html carries the asset names, is not hashed, and must never be cached
              // hard: cache it and a deploy simply never reaches anyone still holding the
              // old copy.
              if (/[\\/]assets[\\/]/.test(filePath)) {
                res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
              } else {
                res.setHeader('Cache-Control', 'no-cache');
              }
            },
          },
        }),
      ]
    : [],
})
export class StaticModule {}
