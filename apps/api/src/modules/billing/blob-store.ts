import {
  DeleteObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import type { ScopedDbService } from '../../common/db/scoped-db.service';

/**
 * Where the bytes of a payment screenshot go (docs/engineering/hosting.md).
 *
 * Three implementations behind one interface, chosen by configuration only:
 *
 *  - **db**: a table in Postgres (ADR-028). For while there is no object storage; the
 *    platform deletes each screenshot once it has decided on it, to keep the database small.
 *  - **s3**: any S3-compatible object store — Cloudflare R2, Backblaze B2, Supabase Storage,
 *    AWS S3. Required on a host whose disk does not survive a restart (Render's free and paid
 *    web services alike), which is every host PharmaEt currently targets.
 *  - **local**: a directory. Development, CI, and a VM with a persistent volume.
 *
 * Moving between providers — R2 today, something else when the business outgrows it — is a
 * change of five environment variables and a bucket copy, never a code change. The storage
 * key is the same string in every backend, so rows in `payment_proof` stay valid.
 */
export interface BlobStore {
  readonly kind: 'local' | 's3' | 'db';
  write(key: string, bytes: Buffer, contentType: string, tenantId: string): Promise<void>;
  read(key: string): Promise<Buffer>;
  /** Deletes the bytes for good. Idempotent: removing what is already gone is not an error. */
  remove(key: string): Promise<void>;
}

/**
 * Screenshots in Postgres (`payment_proof_blob`, ADR-028) — for while there is no object
 * storage. Every call goes through the platform connection, which is logged; the application
 * role has no grant on the table at all.
 */
export class DbBlobStore implements BlobStore {
  readonly kind = 'db' as const;
  constructor(private readonly db: Pick<ScopedDbService, 'runAsPlatform'>) {}

  async write(key: string, bytes: Buffer, _contentType: string, tenantId: string): Promise<void> {
    await this.db.runAsPlatform('store a payment screenshot', (em) =>
      em.query(
        `INSERT INTO payment_proof_blob (storage_key, tenant_id, bytes) VALUES ($1, $2, $3)`,
        [key, tenantId, bytes],
      ),
    );
  }

  async read(key: string): Promise<Buffer> {
    const rows = await this.db.runAsPlatform('read a payment screenshot', (em) =>
      em.query(`SELECT bytes FROM payment_proof_blob WHERE storage_key = $1`, [key]),
    );
    if (!rows.length) throw new Error(`no screenshot at ${key}`);
    return Buffer.from(rows[0].bytes);
  }

  async remove(key: string): Promise<void> {
    await this.db.runAsPlatform('delete a decided payment screenshot', (em) =>
      em.query(`DELETE FROM payment_proof_blob WHERE storage_key = $1`, [key]),
    );
  }
}

export class LocalBlobStore implements BlobStore {
  readonly kind = 'local' as const;
  constructor(private readonly root: string) {}

  async write(key: string, bytes: Buffer): Promise<void> {
    const path = this.path(key);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, bytes, { mode: 0o600 });
  }

  async read(key: string): Promise<Buffer> {
    return readFile(this.path(key));
  }

  async remove(key: string): Promise<void> {
    await rm(this.path(key), { force: true });
  }

  /** Keys come from database rows, never requests; the check is against a future caller. */
  private path(key: string): string {
    const path = resolve(join(this.root, key));
    if (!path.startsWith(resolve(this.root))) throw new Error('invalid storage key');
    return path;
  }
}

export interface S3Settings {
  endpoint: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
}

export class S3BlobStore implements BlobStore {
  readonly kind = 's3' as const;
  private readonly client: Pick<S3Client, 'send'>;

  constructor(
    private readonly settings: S3Settings,
    client?: Pick<S3Client, 'send'>,
  ) {
    this.client =
      client ??
      new S3Client({
        endpoint: settings.endpoint,
        region: settings.region,
        credentials: {
          accessKeyId: settings.accessKeyId,
          secretAccessKey: settings.secretAccessKey,
        },
        // R2 and B2 address buckets by path; virtual-host style needs DNS they do not give.
        forcePathStyle: true,
      });
  }

  async write(key: string, bytes: Buffer, contentType: string): Promise<void> {
    await this.client.send(
      new PutObjectCommand({
        Bucket: this.settings.bucket,
        Key: key,
        Body: bytes,
        // The bytes are ciphertext (ProofStorageService.seal), so the type is metadata only.
        ContentType: contentType,
      }),
    );
  }

  async read(key: string): Promise<Buffer> {
    const result = await this.client.send(
      new GetObjectCommand({ Bucket: this.settings.bucket, Key: key }),
    );
    const body = result.Body as { transformToByteArray(): Promise<Uint8Array> } | undefined;
    if (!body) throw new Error(`no object at ${key}`);
    return Buffer.from(await body.transformToByteArray());
  }

  async remove(key: string): Promise<void> {
    await this.client.send(new DeleteObjectCommand({ Bucket: this.settings.bucket, Key: key }));
  }
}
