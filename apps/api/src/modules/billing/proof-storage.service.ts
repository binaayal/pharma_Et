import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';

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

  constructor(private readonly config: ConfigService) {}

  private get root(): string {
    return resolve(this.config.get<string>('PAYMENT_PROOF_DIR', './.payment-proofs'));
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
    const path = join(this.root, storageKey);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, file.buffer);

    this.logger.log(`stored payment proof ${storageKey} (${file.size} bytes)`);
    return { storageKey, byteSize: file.size, contentType: file.mimetype };
  }

  async get(storageKey: string): Promise<Buffer> {
    // The key comes from a database row, never from a request parameter, so there is no
    // user-controlled path here. The resolve check is belt and braces against a future
    // caller that forgets that.
    const path = resolve(join(this.root, storageKey));
    if (!path.startsWith(resolve(this.root))) {
      throw new BadRequestException('invalid storage key');
    }
    return readFile(path);
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
