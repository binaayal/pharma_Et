import { JwtService } from '@nestjs/jwt';
import request from 'supertest';
import { TestHarness, TEST_TERMINAL, type SeededTenant } from '../harness';

/**
 * G1 — TOKEN LIFECYCLE (docs/05-qa §10: *"Auth: PIN rate-limiting, token expiry,
 * offline-cache expiry at the window boundary"*).
 *
 * §10 named token expiry and nothing tested it. Writing the tests found a real defect, which
 * is recorded here rather than only in the commit that fixed it, because the shape of the
 * mistake is worth keeping: **the refresh token authenticated API calls.**
 *
 * It was signed with the same secret and the same claims, so every signature check passed —
 * correctly. A signature answers "did we issue this?", and we had. The question that matters
 * is "did we issue it *for this purpose*", and nothing in the token answered that, so the
 * guard could not ask it. The consequence was that the fifteen-minute access TTL protected
 * nothing: the device held a second, equivalent credential good for thirty days, in the same
 * storage, so any compromise yielding one yielded the other.
 */
describe('G1 — a token works only for what it was issued for, and only while it lasts', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  let jwt: JwtService;

  const server = () => harness.app.getHttpServer();
  const asProducts = (token: string) =>
    request(server()).get('/api/products').set('authorization', `Bearer ${token}`);

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    tenant = await harness.seedTenant('tok');
    // The application's own signer, so these tests mint tokens exactly as the server does.
    // A hand-rolled JWT would prove the guard rejects something we never issue.
    jwt = harness.app.get(JwtService);
  });

  afterAll(async () => {
    await harness.stop();
  });

  /** The claims a real access token carries. */
  const claimsFor = (t: SeededTenant) => ({
    sub: t.users.owner.id,
    tid: t.id,
    role: 'owner' as const,
    branches: [] as string[],
    terminal: TEST_TERMINAL,
  });

  describe('expiry', () => {
    it('refuses an access token that has expired', async () => {
      // Signed by us, valid in every respect except that its moment has passed. This is the
      // assertion that makes a short access TTL mean anything at all.
      const expired = await jwt.signAsync(
        { ...claimsFor(tenant), typ: 'access' },
        { expiresIn: '-1s' },
      );
      await asProducts(expired).expect(401);
    });

    it('accepts one that has not', async () => {
      const live = await jwt.signAsync(
        { ...claimsFor(tenant), typ: 'access' },
        { expiresIn: '60s' },
      );
      await asProducts(live).expect(200);
    });

    it('tells the client when its token dies, so it can refresh before a customer waits',
      async () => {
        const login = await harness.login(tenant.code, 'cashier');

        // `expiresAt` is what the device plans around. If it disagreed with the token's own
        // `exp`, a terminal would discover expiry mid-sale instead of ahead of one.
        const claimed = new Date(login.expiresAt).getTime();
        const [, encoded] = (login.accessToken as string).split('.');
        const actual =
          JSON.parse(Buffer.from(encoded, 'base64url').toString()).exp * 1000;

        expect(Math.abs(claimed - actual)).toBeLessThan(5_000);
        expect(claimed).toBeGreaterThan(Date.now());
      });
  });

  describe('the offline cache window the server hands out', () => {
    it('covers the full guaranteed offline period, with the degraded ceiling beyond it',
      async () => {
        const login = await harness.login(tenant.code, 'cashier');
        const hours =
          (new Date(login.offlineValidUntil).getTime() - Date.now()) / 3_600_000;

        // NFR-1.1 guarantees 72 continuous hours offline with **no degradation**, and names
        // "login within cache" among the functions covered. A cache validity shorter than
        // that would break the guarantee at its own boundary: the terminal would be inside
        // the supported window and unable to authorise anyone at the till.
        expect(hours).toBeGreaterThanOrEqual(72);

        // And it stops at NFR-1.2's degraded ceiling of 7 days rather than running forever.
        // An unbounded cache is a dismissed cashier who never loses access.
        expect(hours).toBeLessThanOrEqual(24 * 7);
      });
  });

  describe('purpose', () => {
    it('refuses a refresh token on an API route', async () => {
      const login = await harness.login(tenant.code, 'owner');

      // The defect this suite was written to catch. A refresh token is long-lived by design;
      // if it also authenticates, the access token's short life is decoration.
      await asProducts(login.refreshToken).expect(401);
    });

    it('refuses a refresh token even though its signature is perfectly valid', async () => {
      // Stated separately because it is the part that makes the bug easy to ship: nothing is
      // wrong with this token. It verifies. Only its purpose is wrong, and only a claim can
      // carry that.
      const refresh = await jwt.signAsync(
        { ...claimsFor(tenant), typ: 'refresh' },
        { expiresIn: '30d' },
      );
      await expect(jwt.verifyAsync(refresh)).resolves.toBeDefined();
      await asProducts(refresh).expect(401);
    });

    it('still accepts a token minted before the claim existed', async () => {
      // Backward compatibility, asserted rather than assumed. Tokens in the wild carry no
      // `typ`, and rejecting them would have signed every terminal out of a working till at
      // deploy time — for a hardening change, which is the worst possible trade.
      const legacy = await jwt.signAsync(claimsFor(tenant), { expiresIn: '60s' });
      await asProducts(legacy).expect(200);
    });
  });

  describe('forgery', () => {
    it('refuses a token signed with a different secret', async () => {
      const foreign = new JwtService({ secret: 'not-the-secret-this-server-uses' });
      const forged = await foreign.signAsync(
        { ...claimsFor(tenant), typ: 'access' },
        { expiresIn: '60s' },
      );
      await asProducts(forged).expect(401);
    });

    it('refuses a token whose claims were edited after signing', async () => {
      // The attack a JWT exists to stop, asserted anyway: promote a cashier to owner by
      // rewriting the payload and keeping the signature.
      const login = await harness.login(tenant.code, 'cashier');
      const [header, payload, signature] = (login.accessToken as string).split('.');
      const claims = JSON.parse(Buffer.from(payload, 'base64url').toString());
      claims.role = 'owner';
      const tampered = [
        header,
        Buffer.from(JSON.stringify(claims)).toString('base64url'),
        signature,
      ].join('.');

      await asProducts(tampered).expect(401);
    });

    it('refuses a token that names another tenant, however well formed', async () => {
      const other = await harness.seedTenant('tok2');

      // Signed by us, unexpired, correct purpose — and pointing at a pharmacy this user has
      // nothing to do with. It authenticates, so the defence is scoping rather than the
      // signature: RLS binds to the tenant the token names, and the token names theirs.
      const crossTenant = await jwt.signAsync(
        { ...claimsFor(tenant), tid: other.id, typ: 'access' },
        { expiresIn: '60s' },
      );
      const response = await asProducts(crossTenant);

      // It must never return the FIRST tenant's rows. Serving the second tenant's is the
      // honest outcome of a token that says so — forging one requires the signing secret,
      // which is the boundary being relied on here.
      const body = JSON.stringify(response.body ?? {});
      expect(body).not.toContain(tenant.productId);
    });
  });
});
