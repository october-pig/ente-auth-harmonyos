/**
 * 80_hardening_srp_network.test.mjs — Account and platform regression cases G and H.
 *
 * Executes the REAL production modules:
 *   entry/src/main/ets/account/Srp.ets
 *   entry/src/main/ets/account/UserService.ets
 *   entry/src/main/ets/network/HttpClient.ets
 *
 * Upstream authority:
 *   .upstream/pub/lib/srp/srp6_util.dart:69-78   validatePublicValue
 *   .upstream/pub/lib/srp/srp6_client.dart:57-63 calculateSecret (B is reduced)
 *   .upstream/pub/lib/srp/srp6_client.dart:37-46 calculateClientEvidenceMessage
 *                                                (M1 uses the STORED, reduced B)
 *   docs/spec/SRP_SPEC.md:383-413                the same derivation, recorded
 */
import { assert, assertBytes, assertEquals, assertRejects, describe, it } from '../framework.mjs';

const { __resetPreferences, __resetRdb } = await import('../shims/kit-arkdata.mjs');
const { __resetHuks } = await import('../shims/kit-huks.mjs');
const net = await import('../shims/kit-network.mjs');

const { Preferences } = await import('../gen/entry/src/main/ets/storage/Preferences.ts');
const { Configuration } = await import('../gen/entry/src/main/ets/account/Configuration.ts');
const { Srp } = await import('../gen/entry/src/main/ets/account/Srp.ts');
const { UserService } = await import('../gen/entry/src/main/ets/account/UserService.ts');

const N = Srp.N;
const FIVE = 5n;

const server = { requests: [], routes: new Map() };

function respond(req) {
  server.requests.push({ method: req.method, url: req.url, extraData: req.extraData, usingCache: req.usingCache, caPath: req.caPath, caData: req.caData, certificatePinning: req.certificatePinning });
  for (const [match, res] of server.routes) {
    if (req.url.includes(match)) return { responseCode: res.status, result: JSON.stringify(res.body ?? {}) };
  }
  return { responseCode: 404, result: '{}' };
}

async function resetAll() {
  __resetPreferences();
  __resetRdb();
  __resetHuks();
  net.resetHttp();
  server.requests = [];
  server.routes = new Map();
  net.setHttpHandler((req) => respond(req));
  await Preferences.init({});
  await Configuration.instance.init();
}

const b64 = (u8) => Buffer.from(u8).toString('base64');

// ============================================== finding G — public value B

describe('finding G — SRP public value B is validated and reduced', () => {
  it('B = 0 is rejected', () => {
    let threw = false;
    try {
      Srp.validatePublicValue(0n);
    } catch (e) {
      threw = true;
      assert(e.message.includes('Invalid public value'),
        `expected upstream's message, got: ${e.message}`);
    }
    assert(threw, 'B = 0 must be rejected (upstream throws Invalid public value: 0)');
  });

  it('B = N is rejected', () => {
    let threw = false;
    try {
      Srp.validatePublicValue(N);
    } catch (e) {
      threw = true;
    }
    assert(threw, 'B = N reduces to 0 and must be rejected');
  });

  it('B = 2N is rejected', () => {
    let threw = false;
    try {
      Srp.validatePublicValue(2n * N);
    } catch (e) {
      threw = true;
    }
    assert(threw, 'B = 2N reduces to 0 and must be rejected');
  });

  it('B = N + 5 behaves exactly like B = 5', () => {
    assertEquals(Srp.validatePublicValue(N + FIVE), FIVE, 'reduced to 5');
    assertEquals(Srp.validatePublicValue(FIVE), FIVE, '5 is unchanged');
    assertEquals(Srp.validatePublicValue(3n * N + FIVE), FIVE, 'reduced across multiple N');
  });

  it('in-range values are not over-rejected', () => {
    assertEquals(Srp.validatePublicValue(1n), 1n, 'B = 1');
    assertEquals(Srp.validatePublicValue(N - 1n), N - 1n, 'B = N-1');
    assertEquals(Srp.validatePublicValue(N / 2n), N / 2n, 'B = N/2');
  });

  it('calculateSecret REFUSES a raw (unreduced) B', async () => {
    await assertRejects(() => Srp.calculateSecret(N + FIVE, FIVE, 3n, 7n),
      'a raw B must fail loudly rather than be silently reduced here');
  });

  it('calculateM1 REFUSES a raw (unreduced) B', async () => {
    await assertRejects(() => Srp.calculateM1(FIVE, N + FIVE, FIVE),
      'M1 must never be hashed over an unreduced B');
  });

  it('u is derived from the VALIDATED B', async () => {
    const validated = Srp.validatePublicValue(N + FIVE);
    const uFromValidated = await Srp.calculateU(FIVE, validated);
    const uFromFive = await Srp.calculateU(FIVE, FIVE);
    assertEquals(uFromValidated, uFromFive, 'u(N+5 reduced) must equal u(5)');
  });

  it('a full exchange with B and with B + N yields identical S and M1', async () => {
    const A = 12345n;
    const a = 67890n;
    const x = 13579n;
    const B = FIVE;

    const S1 = await Srp.calculateSecret(B, A, a, x);
    const M1 = await Srp.calculateM1(A, B, S1);

    const validated = Srp.validatePublicValue(B + N);
    const S2 = await Srp.calculateSecret(validated, A, a, x);
    const M2 = await Srp.calculateM1(A, validated, S2);

    assertEquals(S2, S1, 'S must be identical after reduction');
    assertEquals(M2, M1, 'M1 must be identical after reduction');
  });

  it('an unreduced B would change what M1 hashes (why the guard matters)', async () => {
    const A2 = 12345n;
    const S2 = 999n;

    // The padded encodings differ, so hashing the raw value would produce a
    // different M1 with no error raised anywhere.
    assertBytes(Srp.getPadded(FIVE, 512), Srp.getPadded(FIVE, 512), 'pad(5) is stable');
    let identical = true;
    const rawPad = Srp.getPadded(N + FIVE, 512);
    const reducedPad = Srp.getPadded(FIVE, 512);
    for (let i = 0; i < rawPad.length; i++) {
      if (rawPad[i] !== reducedPad[i]) { identical = false; break; }
    }
    assertEquals(identical, false,
      'pad(N+5) must differ from pad(5), otherwise the reduction would be a no-op');

    // The reduced form is what upstream hashes, and it equals B = 5.
    const reducedB = Srp.validatePublicValue(N + FIVE);
    assertEquals(await Srp.calculateM1(A2, reducedB, S2), await Srp.calculateM1(A2, FIVE, S2),
      'M1 over the reduced B equals M1 over B = 5');
  });

  it('a value at or above 2^4096 would additionally change the pad width', async () => {
    // `getPadded` does not truncate, so an out-of-range value can also change the
    // LENGTH of the hash input — a second, independent way an unvalidated B
    // corrupts the transcript.
    const TWO_4096 = 1n << 4096n;
    const outOfRange = TWO_4096 + FIVE;
    assertEquals(Srp.getPadded(FIVE, 512).length, 512, 'in-range B pads to 512');
    assertEquals(Srp.getPadded(outOfRange, 512).length, 513,
      'a value >= 2^4096 pads to 513 bytes');
    // Reduction maps it back into range (N is not 2^4096 - 1, so the residue is
    // not simply 5 — only the range and determinism matter here).
    const reduced = Srp.validatePublicValue(outOfRange);
    assertEquals(reduced, outOfRange % N, 'reduce mod N');
    assert(reduced > 0n && reduced < N, 'and the result is in [1, N-1]');
    assertEquals(Srp.getPadded(reduced, 512).length, 512, 'so the pad width is restored');
  });

  /**
   * Seed a complete, honest SRP exchange so the login path can actually reach
   * verify-session. Without this, a rejection test could "pass" merely because
   * the fake server 404s later — which is exactly how a bad test hides a bug.
   */
  function seedSrpExchange(srpB) {
    server.routes.set('/users/srp/attributes', {
      status: 200,
      body: {
        attributes: {
          srpUserID: 'user-id',
          srpSalt: b64(new Uint8Array(16).fill(1)),
          memLimit: 8192,
          opsLimit: 1,
          kekSalt: b64(new Uint8Array(16).fill(2)),
        },
      },
    });
    server.routes.set('/users/srp/create-session', {
      status: 200,
      body: { sessionID: 'sess', srpB },
    });
    server.routes.set('/users/srp/verify-session', {
      status: 200,
      body: { id: 1, token: 'SESSION-TOKEN' },
    });
  }

  const verifySessionCount = () =>
    server.requests.filter((r) => r.url.includes('verify-session')).length;

  it('an in-range B DOES reach verify-session (the path is live)', async () => {
    await resetAll();
    seedSrpExchange(b64(Srp.encodeBigInt(123456789n)));
    const attrs = await UserService.getSrpAttributes('a@example.test');
    const response = await UserService.loginWithPassword('a@example.test', 'pw', attrs);
    assertEquals(response.token, 'SESSION-TOKEN', 'a valid B completes the exchange');
    assertEquals(verifySessionCount(), 1, 'verify-session reached');
  });

  it('a live create-session returning B = 0 fails BEFORE verify-session', async () => {
    await resetAll();
    seedSrpExchange(b64(new Uint8Array(0)));   // decodeBigInt([]) === 0
    const attrs = await UserService.getSrpAttributes('a@example.test');
    await assertRejects(() => UserService.loginWithPassword('a@example.test', 'pw', attrs),
      'a server sending B = 0 must not yield a session');
    assertEquals(verifySessionCount(), 0,
      'M1 must never be computed from an invalid B, so verify-session must not be reached');
  });

  it('a live create-session returning B = N fails BEFORE verify-session', async () => {
    await resetAll();
    seedSrpExchange(b64(Srp.encodeBigInt(N)));
    const attrs = await UserService.getSrpAttributes('a@example.test');
    await assertRejects(() => UserService.loginWithPassword('a@example.test', 'pw', attrs),
      'B = N reduces to 0 and must be rejected');
    assertEquals(verifySessionCount(), 0, 'verify-session must not be reached');
  });

  it('a live create-session returning B = N + 5 behaves like B = 5', async () => {
    await resetAll();
    seedSrpExchange(b64(Srp.encodeBigInt(FIVE)));
    const attrs = await UserService.getSrpAttributes('a@example.test');
    const a = await UserService.loginWithPassword('a@example.test', 'pw', attrs);

    await resetAll();
    seedSrpExchange(b64(Srp.encodeBigInt(N + FIVE)));
    const attrs2 = await UserService.getSrpAttributes('a@example.test');
    const b = await UserService.loginWithPassword('a@example.test', 'pw', attrs2);

    assertEquals(b.token, a.token, 'reduced B must produce an equivalent exchange');
    assertEquals(verifySessionCount(), 1, 'and it must reach verify-session');
  });

  it('the existing SRP vector still passes (no regression)', async () => {
    // x = H(salt || H(identity || ':' || password)) and v = g^x mod N are the
    // parity surface that must not move.
    const salt = new Uint8Array(16).fill(9);
    const identity = new Uint8Array([0x75, 0x73, 0x65, 0x72]); // "user"
    const password = new Uint8Array(32).fill(4);
    const v1 = await Srp.generateVerifier(salt, identity, password);
    const v2 = await Srp.generateVerifier(salt, identity, password);
    assertEquals(v2, v1, 'verifier generation is deterministic');
    assertEquals(Srp.modPow(Srp.g, 1n, N), Srp.g, 'g^1 = g');
    assertEquals(Srp.modPow(Srp.g, 0n, N), 1n, 'g^0 = 1');
    const x = await Srp.calculateX(salt, identity, password);
    assertEquals(Srp.modPow(Srp.g, x, N), v1, 'v == g^x mod N');
  });
});

// ================================================= finding H — API caching

describe('finding H — the API client does not read from the HTTP cache', () => {
  it('a real POST is issued with usingCache === false', async () => {
    await resetAll();
    server.routes.set('/users/ott', { status: 200, body: {} });
    await UserService.sendOtt('a@example.test', 'login', true);
    const req = server.requests.find((r) => r.url.includes('/users/ott'));
    assert(req !== undefined, 'request issued');
    assertEquals(req.usingCache, false,
      'NetworkKit defaults usingCache to true ("prefer reading the cache"); an API client must opt out');
  });

  it('a real GET is issued with usingCache === false', async () => {
    await resetAll();
    server.routes.set('/users/srp/attributes', {
      status: 200,
      body: { attributes: { srpUserID: 'u', srpSalt: 's', memLimit: 1, opsLimit: 1, kekSalt: 'k' } },
    });
    await UserService.getSrpAttributes('a@example.test');
    const req = server.requests.find((r) => r.url.includes('/users/srp/attributes'));
    assert(req !== undefined, 'request issued');
    assertEquals(req.usingCache, false, 'GET must not prefer the cache either');
  });

  it('a real PUT is issued with usingCache === false', async () => {
    await resetAll();
    await Configuration.instance.setToken('SYNTHETIC_SIGNUP_TOKEN');
    server.routes.set('/users/attributes', { status: 200, body: {} });
    const { KeyAttributes } = await import('../gen/entry/src/main/ets/models/KeyAttributes.ts');
    await UserService.setAttributes(new (await import('../gen/entry/src/main/ets/models/KeyAttributes.ts')).KeyGenResult(
      KeyAttributes.fromMap({
        kekSalt: 'a', encryptedKey: 'b', keyDecryptionNonce: 'c', publicKey: 'd',
        encryptedSecretKey: 'e', secretKeyDecryptionNonce: 'f', memLimit: 1, opsLimit: 1,
        masterKeyEncryptedWithRecoveryKey: 'g', masterKeyDecryptionNonce: 'h',
        recoveryKeyEncryptedWithMasterKey: 'i', recoveryKeyDecryptionNonce: 'j',
      }), 'bWFzdGVy', 'aabb', 'c2VjcmV0', new Uint8Array(16).fill(1)), Configuration.instance);
    const req = server.requests.find((r) => r.url.includes('/users/attributes'));
    assert(req !== undefined, 'request issued');
    assertEquals(req.usingCache, false, 'PUT must not use the cache');
  });

  it('TLS verification stays at the system default', async () => {
    await resetAll();
    server.routes.set('/users/ott', { status: 200, body: {} });
    await UserService.sendOtt('a@example.test', 'login', true);
    const req = server.requests[0];
    assertEquals(req.caPath, undefined, 'no custom CA path');
    assertEquals(req.caData, undefined, 'no custom CA data');
    assertEquals(req.certificatePinning, undefined, 'no certificate pinning override');
  });
});
