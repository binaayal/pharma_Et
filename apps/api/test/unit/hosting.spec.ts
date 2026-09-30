import { GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { S3BlobStore } from '../../src/modules/billing/blob-store';
import { ProofStorageService } from '../../src/modules/billing/proof-storage.service';
import { loadConfiguration } from '../../src/config/configuration';
import { httpSecurityFromEnv } from '../../src/common/http/security';

/** Hosting on Render + Neon + R2 (docs/engineering/hosting.md). */
describe('hosting configuration', () => {
  describe('payment screenshots in object storage', () => {
    const settings = {
      endpoint: 'https://acct.r2.cloudflarestorage.com',
      bucket: 'pharmaet-proofs',
      accessKeyId: 'id',
      secretAccessKey: 'secret',
      region: 'auto',
    };

    it('writes to and reads from the bucket, by the same key', async () => {
      const objects = new Map<string, Uint8Array>();
      const client = {
        send: jest.fn(async (command: unknown) => {
          if (command instanceof PutObjectCommand) {
            expect(command.input.Bucket).toBe('pharmaet-proofs');
            objects.set(command.input.Key!, command.input.Body as Uint8Array);
            return {};
          }
          if (command instanceof GetObjectCommand) {
            const bytes = objects.get(command.input.Key!)!;
            return { Body: { transformToByteArray: async () => bytes } };
          }
          throw new Error('unexpected command');
        }),
      };
      const store = new S3BlobStore(settings, client as never);
      await store.write('proofs/t/1', Buffer.from('ciphertext'), 'image/png');
      expect((await store.read('proofs/t/1')).toString()).toBe('ciphertext');
    });

    it('stores only ciphertext when the encryption key is set', async () => {
      // What lands in the bucket is what a leaked R2 token would expose.
      let stored: Buffer | undefined;
      const key = Buffer.alloc(32, 3).toString('base64');
      const config = {
        get: (k: string) => ({ PROOF_STORAGE: 's3', PROOF_ENCRYPTION_KEY: key })[k],
        getOrThrow: (k: string) => `${k}-value`.replace('S3_ENDPOINT-value', 'https://x.example'),
      };
      const service = new ProofStorageService(config as never);
      Object.defineProperty(service, 'store', {
        value: {
          kind: 's3',
          write: async (_k: string, bytes: Buffer) => void (stored = bytes),
          read: async () => stored!,
        },
      });
      const png = Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), Buffer.alloc(16, 1)]);
      const saved = await service.put('tenant', {
        buffer: png,
        mimetype: 'image/png',
        size: png.length,
      });
      expect(stored!.includes(png)).toBe(false);
      expect(await service.get(saved.storageKey)).toEqual(png);
    });
  });

  describe('proxy trust and rate limits from the environment', () => {
    it('turns TRUST_PROXY into a hop COUNT — a string would trust nothing', () => {
      // Express reads `trust proxy = "1"` as the IP address "1". The server then sees the
      // host's proxy as every client, and one login-throttle counter serves every pharmacy.
      expect(httpSecurityFromEnv('production', { TRUST_PROXY: '1' }).trustProxy).toBe(1);
      expect(httpSecurityFromEnv('production', {}).trustProxy).toBe(0);
      expect(httpSecurityFromEnv('production', { TRUST_PROXY: 'x' }).trustProxy).toBe(0);
    });

    it('reads RATE_LIMIT=off as off — the string "off" is truthy', () => {
      expect(httpSecurityFromEnv('production', { RATE_LIMIT: 'off' }).rateLimit).toBe(false);
      expect(httpSecurityFromEnv('production', {}).rateLimit).toBe(true);
      expect(httpSecurityFromEnv('test', {}).rateLimit).toBe(false);
    });
  });

  describe('production refuses a configuration that would lose data', () => {
    const base = {
      NODE_ENV: 'production',
      DATABASE_URL: 'postgres://o:p@db.example/pharmaet',
      DATABASE_APP_PASSWORD: 'x',
      JWT_SECRET: 'a'.repeat(40),
      PROOF_ENCRYPTION_KEY: Buffer.alloc(32, 1).toString('base64'),
    };
    const withEnv = (env: Record<string, string>) => {
      const saved = process.env;
      process.env = { ...env };
      try {
        return loadConfiguration();
      } finally {
        process.env = saved;
      }
    };

    it('an unstated storage backend — the ephemeral-disk trap', () => {
      expect(() => withEnv(base)).toThrow(/PROOF_STORAGE must be set/);
    });

    it('object storage with a missing setting', () => {
      expect(() => withEnv({ ...base, PROOF_STORAGE: 's3', S3_BUCKET: 'b' })).toThrow(
        /S3_ENDPOINT, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY/,
      );
    });

    it('accepts a complete R2 configuration', () => {
      const config = withEnv({
        ...base,
        PROOF_STORAGE: 's3',
        S3_ENDPOINT: 'https://acct.r2.cloudflarestorage.com',
        S3_BUCKET: 'pharmaet-proofs',
        S3_ACCESS_KEY_ID: 'id',
        S3_SECRET_ACCESS_KEY: 'secret',
      });
      expect(config.PROOF_STORAGE).toBe('s3');
    });
  });
});
