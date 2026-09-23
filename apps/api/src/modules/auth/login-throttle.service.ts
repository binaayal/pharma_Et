import { HttpException, HttpStatus, Injectable, Logger } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { uuidv7 } from 'uuidv7';

/**
 * Login throttling (NFR-4.2, ADR-017).
 *
 * Counter login is a four-digit PIN — ten thousand possibilities, chosen for speed at the
 * till. Unthrottled, that is minutes of work. And because every audit entry and every
 * cash-up variance rests on *who was signed in*, a guessable PIN does not merely expose an
 * account; it makes the product's central claim to an owner untrue.
 *
 * **It throttles the attempt and never locks the account.** Lockout would be a
 * denial-of-service against the pharmacy: in a shop with one terminal and one cashier,
 * anyone who knows the pharmacy code and a username — neither is secret — could close the
 * business. A control that hands an attacker a better weapon than the one it removes is not
 * a control. ADR-017 has the full argument.
 *
 * What makes throttling safe here is the offline-first design: a terminal that is already
 * signed in holds a cached session and keeps trading throughout (BR-2.3). The attacker is
 * slowed; the shop is untouched.
 */
@Injectable()
export class LoginThrottleService {
  private readonly logger = new Logger(LoginThrottleService.name);

  /** Five attempts on one username, twenty from one address, in fifteen minutes. */
  private static readonly WINDOW_MINUTES = 15;
  private static readonly MAX_PER_IDENTITY = 5;
  private static readonly MAX_PER_SOURCE = 20;

  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  /**
   * Called **before** the credential is checked, and identically for every input.
   *
   * Checking first, and counting attempts against whatever strings were supplied — existing
   * or not — is what stops the limiter becoming the account-enumeration oracle that the
   * uniform login error was written to prevent. "Throttled" must not mean "this user
   * exists".
   */
  async assertNotThrottled(tenantCode: string, username: string, sourceIp: string): Promise<void> {
    const since = new Date(Date.now() - LoginThrottleService.WINDOW_MINUTES * 60_000);

    const [identity, source] = await Promise.all([
      this.countFailures(
        `tenant_code = $1 AND username = $2 AND attempted_at > $3`,
        [tenantCode.toLowerCase(), username.toLowerCase(), since],
      ),
      this.countFailures(`source_ip = $1 AND attempted_at > $2`, [sourceIp, since]),
    ]);

    if (identity >= LoginThrottleService.MAX_PER_IDENTITY) {
      this.logger.warn(`throttled: ${identity} recent failures for ${tenantCode}/${username}`);
      throw LoginThrottleService.tooManyAttempts();
    }
    if (source >= LoginThrottleService.MAX_PER_SOURCE) {
      // The limit that actually catches somebody walking the username space; the per-user
      // one alone would let them try five PINs against every cashier in the tenant.
      this.logger.warn(`throttled: ${source} recent failures from ${sourceIp}`);
      throw LoginThrottleService.tooManyAttempts();
    }
  }

  /**
   * Records the outcome.
   *
   * A success **clears** the identity's recent failures: a cashier who fumbles four times
   * and then gets it right should not spend the rest of the day one mistake from a
   * throttle.
   */
  async record(
    tenantCode: string,
    username: string,
    sourceIp: string,
    succeeded: boolean,
  ): Promise<void> {
    const code = tenantCode.toLowerCase();
    const user = username.toLowerCase();

    if (succeeded) {
      await this.dataSource.query(
        `DELETE FROM login_attempt WHERE tenant_code = $1 AND username = $2 AND succeeded = false`,
        [code, user],
      );
    }

    await this.dataSource.query(
      `INSERT INTO login_attempt (id, tenant_code, username, source_ip, succeeded)
       VALUES ($1, $2, $3, $4, $5)`,
      [uuidv7(), code, user, sourceIp, succeeded],
    );
  }

  private async countFailures(where: string, params: unknown[]): Promise<number> {
    const rows = await this.dataSource.query(
      `SELECT count(*)::int AS n FROM login_attempt WHERE succeeded = false AND ${where}`,
      params,
    );
    const result = Array.isArray(rows[0]) ? rows[0] : rows;
    return Number(result[0]?.n ?? 0);
  }

  /**
   * `429` with `Retry-After`, and a message that says what to do.
   *
   * Deliberately identical whatever triggered it. A message that distinguished "this user is
   * throttled" from "this address is throttled" would tell an attacker which of their
   * guesses named something real.
   */
  private static tooManyAttempts(): HttpException {
    return new HttpException(
      {
        statusCode: HttpStatus.TOO_MANY_REQUESTS,
        error: 'Too many attempts',
        message:
          `Too many sign-in attempts. Try again in ${LoginThrottleService.WINDOW_MINUTES} ` +
          `minutes. A terminal that is already signed in keeps working — this does not stop ` +
          `you selling.`,
        retryAfterSeconds: LoginThrottleService.WINDOW_MINUTES * 60,
      },
      HttpStatus.TOO_MANY_REQUESTS,
    );
  }
}
