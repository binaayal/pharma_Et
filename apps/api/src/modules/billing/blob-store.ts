import { GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';

/**
 * Where the bytes of a payment screenshot go (docs/engineering/hosting.md).
 *
 * Two implementations behind one interface, chosen by configuration only:
 *
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
  readonly kind: 'local' | 's3';
  write(key: string, bytes: Buffer, contentType: string): Promise<void>;
  read(key: string): Promise<Buffer>;
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
}
