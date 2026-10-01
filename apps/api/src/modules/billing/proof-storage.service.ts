import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createCipheriv, createDecipheriv, createHash, randomBytes, randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import { type BlobStore, DbBlobStore, LocalBlobStore, S3BlobStore } from './blob-store';

/**
 * Where a payment screenshot actually lives (docs/04 §5.8).
 *
 * Object storage in production; the local filesystem in development, behind the same
 * interface. Not a stub — a stub would let the whole verification flow "work" in tests while
 * the one step that touches a real file was never exercised, and that step is the one that
 * fails on the day it matters.
 *
 * Screenshots never go in the database. A BYTEA column of phone photographs bloats every
 * backup and every restore, and the restore drill is a GA gate (`06` §11).
 */
@Injectable()
export class ProofStorageService {
  private readonly logger = new Logger(ProofStorageService.name);

  /** Phone screenshots. Anything else is either a mistake or someone probing. */
  private static readonly ALLOWED_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
  private static readonly MAX_BYTES = 8 * 1024 * 1024;

  /**
   * Marks an encrypted file: `PEP1` ‖ 12-byte IV ‖ 16-byte GCM tag ‖ ciphertext.
   *
   * A screenshot of a transfer shows a name, an account number and a balance. At rest it is
   * AES-256-GCM under PROOF_ENCRYPTION_KEY, so a copied disk, a leaked backup or a volume
   * snapshot yields noise — and GCM's tag means a file altered on disk fails to open rather
   * than showing a reviewer a doctored image. Files written before the key existed have no
   * marker and are read as they are; nothing needs migrating.
   */
  private static readonly MAGIC = Buffer.from('PEP1');

  constructor(
    private readonly config: ConfigService,
    private readonly db?: ScopedDbService,
  ) {}

  private get key(): Buffer | null {
    const b64 = this.config.get<string>('PROOF_ENCRYPTION_KEY');
    return b64 ? Buffer.from(b64, 'base64') : null;
  }

  /** Exposed for the suite that proves the bytes on disk are not the image. */
  seal(plain: Buffer): Buffer {
    const key = this.key;
    if (!key) return plain;
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', key, iv);
    const body = Buffer.concat([cipher.update(plain), cipher.final()]);
    return Buffer.concat([ProofStorageService.MAGIC, iv, cipher.getAuthTag(), body]);
  }

  open(stored: Buffer): Buffer {
    if (!stored.subarray(0, 4).equals(ProofStorageService.MAGIC)) return stored;
    const key = this.key;
    if (!key) throw new BadRequestException('this proof is encrypted and no key is configured');
    const decipher = createDecipheriv('aes-256-gcm', key, stored.subarray(4, 16));
    decipher.setAuthTag(stored.subarray(16, 32));
    return Buffer.concat([decipher.update(stored.subarray(32)), decipher.final()]);
  }

  private store?: BlobStore;

  /**
   * The backend, chosen once from configuration (`PROOF_STORAGE`, see blob-store.ts).
   * Built lazily so a unit test that only seals and opens needs no configuration at all.
   */
  get blobs(): BlobStore {
    if (this.store) return this.store;
    const kind = this.config.get<string>('PROOF_STORAGE');
    if (kind === 'db') {
      if (!this.db) throw new Error('PROOF_STORAGE=db needs the database service');
      this.store = new DbBlobStore(this.db);
    } else if (kind === 's3') {
      this.store = new S3BlobStore({
        endpoint: this.config.getOrThrow<string>('S3_ENDPOINT'),
        bucket: this.config.getOrThrow<string>('S3_BUCKET'),
        accessKeyId: this.config.getOrThrow<string>('S3_ACCESS_KEY_ID'),
        secretAccessKey: this.config.getOrThrow<string>('S3_SECRET_ACCESS_KEY'),
        region: this.config.get<string>('S3_REGION') ?? 'auto',
      });
    } else {
      this.store = new LocalBlobStore(
        resolve(this.config.get<string>('PAYMENT_PROOF_DIR') ?? './.payment-proofs'),
      );
    }
    return this.store;
  }

  /**
   * Stores a screenshot and returns its key.
   *
   * The key embeds the tenant and a random id. The tenant prefix keeps one pharmacy's
   * proofs together for retention and deletion; the random component means a key cannot be
   * guessed from a tenant id, so a leaked key exposes one image rather than a directory.
   */
  async put(
    tenantId: string,
    file: { buffer: Buffer; mimetype: string; size: number },
  ): Promise<{ storageKey: string; byteSize: number; contentType: string }> {
    if (!ProofStorageService.ALLOWED_TYPES.has(file.mimetype)) {
      throw new BadRequestException(
        `a payment proof must be a JPEG, PNG or WebP image; received ${file.mimetype}`,
      );
    }
    if (file.size <= 0 || file.size > ProofStorageService.MAX_BYTES) {
      throw new BadRequestException('a payment proof must be between 1 byte and 8 MB');
    }
    // Trust the bytes, not the declared type: a client can claim any mimetype, and the
    // magic number is what a viewer will actually act on.
    if (!ProofStorageService.looksLikeImage(file.buffer)) {
      throw new BadRequestException('that file is not a JPEG, PNG or WebP image');
    }

    const storageKey = `proofs/${tenantId}/${randomUUID()}`;
    await this.blobs.write(storageKey, this.seal(file.buffer), file.mimetype, tenantId);

    this.logger.log(`stored payment proof ${storageKey} (${file.size} bytes)`);
    return { storageKey, byteSize: file.size, contentType: file.mimetype };
  }

  async get(storageKey: string): Promise<Buffer> {
    // The key comes from a database row, never from a request parameter.
    return this.open(await this.blobs.read(storageKey));
  }

  /** Deletes a screenshot's bytes for good (ADR-028). */
  async remove(storageKey: string): Promise<void> {
    await this.blobs.remove(storageKey);
  }

  /** Content-based type check. The first bytes of a file are harder to lie about. */
  private static looksLikeImage(buffer: Buffer): boolean {
    if (buffer.length < 12) return false;
    const jpeg = buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff;
    const png =
      buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4e && buffer[3] === 0x47;
    const webp =
      buffer.toString('ascii', 0, 4) === 'RIFF' && buffer.toString('ascii', 8, 12) === 'WEBP';
    return jpeg || png || webp;
  }

  /** A stable fingerprint, so the same screenshot submitted twice is recognisable. */
  static fingerprint(buffer: Buffer): string {
    return createHash('sha256').update(buffer).digest('hex');
  }
}
