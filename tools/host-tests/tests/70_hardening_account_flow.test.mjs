/**
 * 70_hardening_account_flow.test.mjs — Account and platform regression cases B, C, D, E, F.
 *
 * Executes the REAL production modules:
 *   entry/src/main/ets/account/UserService.ets
 *   entry/src/main/ets/account/Configuration.ets
 *   entry/src/main/ets/storage/Preferences.ets
 *
 * against a programmable in-process HTTP transport.
 *
 * Upstream authority (pinned, re-verified byte-identical to GitHub at
 * 3cc9103a3126de07f79a4465cf0b9922903de54b in this session):
 *   packages/accounts/lib/services/user_service.dart
 *   packages/accounts/lib/pages/password_entry_page.dart
 *   packages/accounts/lib/pages/recovery_key_page.dart
 *   packages/accounts/lib/pages/password_reentry_page.dart
 *   packages/configuration/lib/base_configuration.dart
 *   packages/configuration/lib/constants.dart
 */
import { assert, assertEquals, assertRejects, describe, it } from '../framework.mjs';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..', '..');

const { __resetPreferences, __resetRdb, __pendingWrites } = await import('../shims/kit-arkdata.mjs');
const { __resetHuks } = await import('../shims/kit-huks.mjs');
const net = await import('../shims/kit-network.mjs');

const { Preferences } = await import('../gen/entry/src/main/ets/storage/Preferences.ts');
const { Configuration } = await import('../gen/entry/src/main/ets/account/Configuration.ts');
const { UserService, SrpSetupNotCompleteError } =
  await import('../gen/entry/src/main/ets/account/UserService.ts');
const { KeyAttributes, KeyGenResult } =
  await import('../gen/entry/src/main/ets/models/KeyAttributes.ts');
const { EventBus, Events } = await import('../gen/entry/src/main/ets/events/EventBus.ts');

const PRODUCTION = 'https://api.ente.com';
const CUSTOM = 'https://api.example.test';

/** A minimal, syntactically valid KeyAttributes object. */
function sampleKeyAttributes(tag) {
  return {
    kekSalt: `kekSalt-${tag}`,
    encryptedKey: `encryptedKey-${tag}`,
    keyDecryptionNonce: `keyNonce-${tag}`,
    publicKey: `publicKey-${tag}`,
    encryptedSecretKey: `encSecretKey-${tag}`,
    secretKeyDecryptionNonce: `secretNonce-${tag}`,
    memLimit: 1073741824,
    opsLimit: 4,
    masterKeyEncryptedWithRecoveryKey: `mkRecovery-${tag}`,
    masterKeyDecryptionNonce: `mkNonce-${tag}`,
    recoveryKeyEncryptedWithMasterKey: `rkMaster-${tag}`,
    recoveryKeyDecryptionNonce: `rkNonce-${tag}`,
  };
}

// --------------------------------------------------------------- test harness

const server = {
  requests: [],
  /** url substring -> { status, body } */
  routes: new Map(),
  /** if set, every request throws this (transport failure) */
  transportError: null,
};

function route(match, status, body) {
  server.routes.set(match, { status, body });
}

function respond(req) {
  server.requests.push({
    method: req.method,
    url: req.url,
    extraData: req.extraData,
    header: req.header,
    usingCache: req.usingCache,
  });
  if (server.transportError) throw new Error(server.transportError);
  for (const [match, res] of server.routes) {
    if (req.url.includes(match)) {
      return { responseCode: res.status, result: JSON.stringify(res.body ?? {}) };
    }
  }
  return { responseCode: 404, result: '{}' };
}

function requestsTo(sub) {
  return server.requests.filter((r) => r.url.includes(sub));
}

const events = [];

async function resetAll() {
  __resetPreferences();
  __resetRdb();
  __resetHuks();
  net.resetHttp();
  EventBus.clear();
  events.length = 0;
  for (const e of [Events.SIGNED_IN, Events.SIGNED_OUT]) {
    EventBus.on(e, () => events.push(e));
  }
  server.requests = [];
  server.routes = new Map();
  server.transportError = null;
  net.setHttpHandler((req) => respond(req));
  await Preferences.init({});
  await Configuration.instance.init();
}

const config = () => Configuration.instance;

// ============================================================ finding B — 2FA

describe('finding B — 2FA goes through the canonical LoginResponse parser', () => {
  it('a 2FA response with encryptedToken + keyAttributes keeps them intact', async () => {
    await resetAll();
    route('/users/two-factor/verify', 200, {
      id: 4242,
      encryptedToken: 'ENCRYPTED-TOKEN',
      keyAttributes: sampleKeyAttributes('twofa'),
    });
    const response = await UserService.verifyTwoFactor('session-1', '123456');
    assertEquals(response.id, 4242, 'id parsed');
    assertEquals(response.encryptedToken, 'ENCRYPTED-TOKEN', 'encryptedToken parsed');
    assert(response.keyAttributes !== undefined,
      'keyAttributes MUST be parsed for a 2FA response that carries encryptedToken');
    assertEquals(response.keyAttributes.kekSalt, 'kekSalt-twofa', 'keyAttributes content');
  });

  it('saveLoginResponse persists the 2FA keyAttributes into Configuration', async () => {
    await resetAll();
    route('/users/two-factor/verify', 200, {
      id: 4242,
      encryptedToken: 'ENCRYPTED-TOKEN',
      keyAttributes: sampleKeyAttributes('twofa'),
    });
    const response = await UserService.verifyTwoFactor('session-1', '123456');
    await UserService.saveLoginResponse(response, config());
    const stored = config().getKeyAttributes();
    assert(stored !== undefined,
      'after a successful 2FA login the account must still have keyAttributes');
    assertEquals(stored.kekSalt, 'kekSalt-twofa', 'persisted content');
    assertEquals(config().getUserId(), 4242, 'userId persisted');
    assertEquals(config().getEncryptedToken(), 'ENCRYPTED-TOKEN', 'encryptedToken persisted');
  });

  it('the 2FA request body and endpoint are unchanged', async () => {
    await resetAll();
    route('/users/two-factor/verify', 200, { id: 1, encryptedToken: 'x', keyAttributes: sampleKeyAttributes('a') });
    await UserService.verifyTwoFactor('session-9', '  654321  '.trim());
    const reqs = requestsTo('/users/two-factor/verify');
    assertEquals(reqs.length, 1, 'one request');
    assertEquals(reqs[0].method, 'POST', 'POST');
    assertEquals(JSON.parse(reqs[0].extraData), { sessionID: 'session-9', code: '654321' }, 'body');
  });

  it('a 404 from 2FA surfaces a session-expired error', async () => {
    await resetAll();
    route('/users/two-factor/verify', 404, {});
    await assertRejects(() => UserService.verifyTwoFactor('session-1', '123456'),
      'a 404 must reject');
  });

  it('a malformed encryptedToken response WITHOUT keyAttributes fails loudly', async () => {
    await resetAll();
    route('/users/two-factor/verify', 200, { id: 4242, encryptedToken: 'ENCRYPTED-TOKEN' });
    const response = await UserService.verifyTwoFactor('session-1', '123456');
    assertEquals(response.keyAttributes, undefined, 'nothing to parse');
    await assertRejects(() => UserService.saveLoginResponse(response, config()),
      'upstream KeyAttributes.fromMap(null) throws; this must too');
  });

  it('a malformed response must NOT erase existing keyAttributes', async () => {
    await resetAll();
    const existing = KeyAttributes.fromMap(sampleKeyAttributes('pre-existing'));
    await config().setKeyAttributes(existing);
    route('/users/two-factor/verify', 200, { id: 4242, encryptedToken: 'ENCRYPTED-TOKEN' });
    const response = await UserService.verifyTwoFactor('session-1', '123456');
    await assertRejects(() => UserService.saveLoginResponse(response, config()));
    const stillThere = config().getKeyAttributes();
    assert(stillThere !== undefined,
      'a malformed login response must never be able to clear the account security state');
    assertEquals(stillThere.kekSalt, 'kekSalt-pre-existing', 'unchanged');
    assertEquals(await Preferences.getString('key_attributes') !== undefined, true,
      'and it must still be on disk');
  });

  it('the plain token login path is unchanged and does not touch keyAttributes', async () => {
    await resetAll();
    const existing = KeyAttributes.fromMap(sampleKeyAttributes('pre-existing'));
    await config().setKeyAttributes(existing);
    route('/users/verify-email', 200, { id: 7, token: 'PLAIN-TOKEN' });
    const response = await UserService.verifyEmail('a@example.test', '123456', undefined);
    assertEquals(response.token, 'PLAIN-TOKEN', 'token parsed');
    assertEquals(response.keyAttributes, undefined, 'no keyAttributes on the token path');
    await UserService.saveLoginResponse(response, config());
    assertEquals(config().getToken(), 'PLAIN-TOKEN', 'token stored');
    assertEquals(config().getKeyAttributes().kekSalt, 'kekSalt-pre-existing',
      'the token path must not clear existing keyAttributes');
  });

  it('twoFactorSessionIDV2 is used only when twoFactorSessionID is empty', async () => {
    await resetAll();
    route('/users/verify-email', 200, { id: 1, twoFactorSessionID: 'V1', twoFactorSessionIDV2: 'V2' });
    const a = await UserService.verifyEmail('a@example.test', '123456', undefined);
    assertEquals(a.twoFactorSessionID, 'V1', 'V1 wins when present');

    await resetAll();
    route('/users/verify-email', 200, { id: 1, twoFactorSessionIDV2: 'V2' });
    const b = await UserService.verifyEmail('a@example.test', '123456', undefined);
    assertEquals(b.twoFactorSessionID, 'V2', 'V2 used when V1 is absent');
  });

  it('SOURCE CONTRACT: the 2FA page does not build a LoginResponse itself', async () => {
    // The host harness cannot execute an ArkUI @Component, so the UI half of
    // finding B is guarded structurally. This proves ONLY that the duplicated
    // parsing is gone; the behaviour above is what proves the fix works.
    const src = readFileSync(join(REPO, 'entry/src/main/ets/pages/OnboardingFlow.ets'), 'utf8');
    assert(!src.includes('new LoginResponse()'),
      'the UI must not construct LoginResponse; UserService owns the parser');
    assert(src.includes('UserService.verifyTwoFactor('),
      'the 2FA page must delegate to UserService.verifyTwoFactor');
    assert(!/HttpClient\.post\(\s*'\/users\/two-factor\/verify'/.test(src),
      'the UI must not post the 2FA endpoint directly');
  });
});

// ================================================= finding C — signup ordering

describe('finding C — signup commits only after the recovery key is confirmed', () => {
  it('UserService.setAttributes issues PUT /users/attributes exactly once', async () => {
    await resetAll();
    await config().setToken('SYNTHETIC_SIGNUP_TOKEN');
    route('/users/attributes', 200, {});
    route('/users/srp/setup', 500, {});
    const result = new KeyGenResult(
      KeyAttributes.fromMap(sampleKeyAttributes('signup')),
      Buffer.from('master-key-32-bytes-padding-000').toString('base64'),
      'aabbccdd',
      Buffer.from('secret-key-32-bytes-padding-000').toString('base64'),
      new Uint8Array(16).fill(7));
    await UserService.setAttributes(result, config());
    assertEquals(requestsTo('/users/attributes').length, 1, 'exactly one PUT');
    assertEquals(requestsTo('/users/attributes')[0].method, 'PUT', 'PUT');
    const body = JSON.parse(requestsTo('/users/attributes')[0].extraData);
    assertEquals(Object.keys(body), ['keyAttributes'], 'body shape');
    assertEquals(body.keyAttributes.kekSalt, 'kekSalt-signup', 'keyAttributes uploaded');
  });

  it('the PUT happens BEFORE any local persistence', async () => {
    await resetAll();
    await config().setToken('SYNTHETIC_SIGNUP_TOKEN');
    const order = [];
    server.routes.set('/users/attributes', { status: 200, body: {} });
    // Record request order, then observe local state at that moment.
    net.setHttpHandler(async (req) => {
      server.requests.push({ method: req.method, url: req.url, extraData: req.extraData });
      if (req.url.includes('/users/attributes')) {
        // At PUT time nothing may be persisted yet.
        order.push(`put:keyAttrsPref=${await Preferences.getString('key_attributes') !== undefined}`);
      }
      if (req.url.includes('/users/srp/setup')) {
        order.push(`srp:keyAttrsPref=${await Preferences.getString('key_attributes') !== undefined}`);
      }
      return { responseCode: req.url.includes('/users/srp/setup') ? 500 : 200, result: '{}' };
    });
    const result = new KeyGenResult(
      KeyAttributes.fromMap(sampleKeyAttributes('order')),
      Buffer.from('master-key-32-bytes-padding-000').toString('base64'),
      'aabbccdd',
      Buffer.from('secret-key-32-bytes-padding-000').toString('base64'),
      new Uint8Array(16).fill(7));
    await UserService.setAttributes(result, config());
    assertEquals(order[0], 'put:keyAttrsPref=false',
      'keyAttributes must NOT be persisted before the server accepted them');
    assertEquals(order[1], 'srp:keyAttrsPref=true',
      'by SRP setup time all three values must be persisted');
  });

  it('all three values are persisted after confirmation', async () => {
    await resetAll();
    await config().setToken('SYNTHETIC_SIGNUP_TOKEN');
    route('/users/attributes', 200, {});
    route('/users/srp/setup', 500, {});
    const master = Buffer.from('master-key-32-bytes-padding-000').toString('base64');
    const secret = Buffer.from('secret-key-32-bytes-padding-000').toString('base64');
    const result = new KeyGenResult(
      KeyAttributes.fromMap(sampleKeyAttributes('persist')), master, 'aabbccdd', secret,
      new Uint8Array(16).fill(7));
    await UserService.setAttributes(result, config());
    assert(config().getKey() !== undefined, 'master key persisted');
    assert(config().getSecretKey() !== undefined, 'secret key persisted');
    assert(config().getKeyAttributes() !== undefined, 'keyAttributes persisted');
    assertEquals(config().getKeyAttributes().kekSalt, 'kekSalt-persist', 'content');
  });

  it('a failed PUT persists nothing and propagates', async () => {
    await resetAll();
    await config().setToken('SYNTHETIC_SIGNUP_TOKEN');
    route('/users/attributes', 500, {});
    const result = new KeyGenResult(
      KeyAttributes.fromMap(sampleKeyAttributes('fail')), 'bWFzdGVy', 'aabbccdd', 'c2VjcmV0',
      new Uint8Array(16).fill(7));
    await assertRejects(() => UserService.setAttributes(result, config()), 'must reject');
    assertEquals(config().getKeyAttributes(), undefined, 'nothing persisted');
    assertEquals(config().getKey(), undefined, 'no master key');
    assertEquals(requestsTo('/users/srp/setup').length, 0, 'SRP never attempted');
  });

  it('an SRP setup failure does not fail signup and keeps the keys', async () => {
    await resetAll();
    await config().setToken('SYNTHETIC_SIGNUP_TOKEN');
    route('/users/attributes', 200, {});
    route('/users/srp/setup', 500, {});
    const result = new KeyGenResult(
      KeyAttributes.fromMap(sampleKeyAttributes('srpfail')),
      Buffer.from('master-key-32-bytes-padding-000').toString('base64'), 'aabbccdd',
      Buffer.from('secret-key-32-bytes-padding-000').toString('base64'),
      new Uint8Array(16).fill(7));
    await UserService.setAttributes(result, config());   // must NOT throw
    assertEquals(requestsTo('/users/srp/setup').length, 1, 'SRP was attempted');
    assert(config().getKey() !== undefined, 'master key still persisted');
    assert(config().getKeyAttributes() !== undefined, 'keyAttributes still persisted');
  });

  it('SOURCE CONTRACT: the signup UI performs no part of the transaction', async () => {
    const src = readFileSync(join(REPO, 'entry/src/main/ets/pages/OnboardingFlow.ets'), 'utf8');
    const completeSignup = src.slice(src.indexOf('private async completeSignup'),
      src.indexOf('private async completeSignup') + 1400);
    assert(!completeSignup.includes('setAttributes('),
      'completeSignup must not upload attributes before the recovery key is shown');
    assert(!completeSignup.includes('setKeyAttributes('),
      'completeSignup must not persist keyAttributes before confirmation');
    const finishSignup = src.slice(src.indexOf('private async finishSignup'),
      src.indexOf('private async finishSignup') + 900);
    assert(finishSignup.includes('UserService.setAttributes('),
      'finishSignup must run the transaction after confirmation');
  });
});

// ==================================================== finding D — SRP retry

describe('finding D — SRP setup is retried on password reentry', () => {
  const KEK = new Uint8Array(32).fill(3);

  it('SRP attributes exist (200) → NO registration is attempted', async () => {
    await resetAll();
    await config().setEmail('a@example.test');
    await config().setToken('SYNTHETIC_SRP_SESSION');
    route('/users/srp/attributes', 200, { attributes: { srpUserID: 'u', srpSalt: 's', memLimit: 1, opsLimit: 1, kekSalt: 'k' } });
    await UserService.registerSrpForExistingUsers('a@example.test', KEK);
    assertEquals(requestsTo('/users/srp/setup').length, 0,
      'an account that already has SRP must not be re-registered');
  });

  it('SRP attributes 404 → EXACTLY ONE registration', async () => {
    await resetAll();
    await config().setEmail('a@example.test');
    await config().setToken('SYNTHETIC_SRP_SESSION');
    route('/users/srp/attributes', 404, {});
    route('/users/srp/setup', 500, {});       // setup itself may fail; we count attempts
    await UserService.registerSrpForExistingUsers('a@example.test', KEK);
    assertEquals(requestsTo('/users/srp/attributes').length, 1, 'one lookup');
    assertEquals(requestsTo('/users/srp/setup').length, 1,
      'exactly one registration attempt for SrpSetupNotCompleteError');
  });

  it('an unexpected 500 does NOT trigger registration', async () => {
    await resetAll();
    await config().setEmail('a@example.test');
    await config().setToken('SYNTHETIC_SRP_SESSION');
    route('/users/srp/attributes', 500, {});
    await UserService.registerSrpForExistingUsers('a@example.test', KEK);
    assertEquals(requestsTo('/users/srp/setup').length, 0,
      'a transient server error must never be mistaken for "SRP does not exist"');
  });

  it('a transport error does NOT trigger registration', async () => {
    await resetAll();
    await config().setEmail('a@example.test');
    await config().setToken('SYNTHETIC_SRP_SESSION');
    server.transportError = 'network down';
    await UserService.registerSrpForExistingUsers('a@example.test', KEK);
    assertEquals(requestsTo('/users/srp/setup').length, 0, 'no registration');
  });

  it('a registration failure does not destroy the session and does not throw', async () => {
    await resetAll();
    await config().setEmail('a@example.test');
    await config().setToken('SYNTHETIC_SRP_SESSION');
    route('/users/srp/attributes', 404, {});
    route('/users/srp/setup', 500, {});
    await config().setToken('SESSION-TOKEN');
    await config().setKeyAttributes(KeyAttributes.fromMap(sampleKeyAttributes('session')));
    // Must resolve, not reject: the user is already logged in.
    await UserService.registerSrpForExistingUsers('a@example.test', KEK);
    assertEquals(config().getToken(), 'SESSION-TOKEN', 'session token intact');
    assertEquals(config().getKeyAttributes().kekSalt, 'kekSalt-session', 'key attributes intact');
  });

  it('SrpSetupNotCompleteError is raised ONLY for a 404', async () => {
    await resetAll();
    await config().setEmail('a@example.test');
    await config().setToken('SYNTHETIC_SRP_SESSION');
    route('/users/srp/attributes', 404, {});
    let err = null;
    try {
      await UserService.getSrpAttributes('a@example.test');
    } catch (e) {
      err = e;
    }
    assert(err instanceof SrpSetupNotCompleteError, '404 → SrpSetupNotCompleteError');

    await resetAll();
    await config().setEmail('a@example.test');
    await config().setToken('SYNTHETIC_SRP_SESSION');
    route('/users/srp/attributes', 500, {});
    err = null;
    try {
      await UserService.getSrpAttributes('a@example.test');
    } catch (e) {
      err = e;
    }
    assert(err !== null, '500 rejects');
    assert(!(err instanceof SrpSetupNotCompleteError),
      'a 500 must NOT be reported as SrpSetupNotCompleteError');
  });
});

// ======================================================= finding E — logout

describe('finding E — logout mirrors upstream remote/local semantics', () => {
  async function primeSession() {
    await resetAll();
    await config().setToken('SESSION-TOKEN');
    await config().setKeyAttributes(KeyAttributes.fromMap(sampleKeyAttributes('logout')));
    await config().setEncryptedToken('ENC');
    await config().setUserId(99);
    events.length = 0;
  }

  it('production + 200 → remote called AND local state cleared', async () => {
    await primeSession();
    route('/users/logout', 200, {});
    await UserService.logout();
    assertEquals(requestsTo('/users/logout').length, 1, 'remote logout issued');
    assertEquals(config().getToken(), undefined, 'token cleared');
    assertEquals(config().getEncryptedToken(), undefined, 'encrypted token cleared');
    assertEquals(config().getKeyAttributes(), undefined, 'keyAttributes cleared');
    assertEquals(config().getUserId(), undefined, 'userId cleared');
    assert(events.includes(Events.SIGNED_OUT), 'SignedOutEvent fired');
  });

  it('production + 401 → local state cleared (token already invalid)', async () => {
    await primeSession();
    route('/users/logout', 401, {});
    await UserService.logout();
    assertEquals(config().getToken(), undefined, 'token cleared');
    assertEquals(config().getKeyAttributes(), undefined, 'keyAttributes cleared');
  });

  it('production + 500 → local state RETAINED and the error is thrown', async () => {
    await primeSession();
    route('/users/logout', 500, {});
    await assertRejects(() => UserService.logout(),
      'a production server failure must not be a silent local logout');
    assertEquals(config().getToken(), 'SESSION-TOKEN',
      'local session must survive so the user can retry');
    assertEquals(config().getKeyAttributes().kekSalt, 'kekSalt-logout',
      'keyAttributes must survive');
    assert(!events.includes(Events.SIGNED_OUT), 'no SignedOutEvent');
  });

  it('production + transport error → local state RETAINED and the error is thrown', async () => {
    await primeSession();
    server.transportError = 'connection refused';
    await assertRejects(() => UserService.logout(), 'transport failure must throw');
    assertEquals(config().getToken(), 'SESSION-TOKEN', 'local session retained');
    assertEquals(config().getKeyAttributes().kekSalt, 'kekSalt-logout', 'keyAttributes retained');
    assert(!events.includes(Events.SIGNED_OUT), 'no SignedOutEvent');
  });

  it('non-production + 500 → local logout proceeds (upstream parity)', async () => {
    await primeSession();
    await config().setEndpoint(CUSTOM);
    route('/users/logout', 500, {});
    await UserService.logout();
    assertEquals(config().getToken(), undefined, 'custom endpoint logs out locally anyway');
    assert(events.includes(Events.SIGNED_OUT), 'SignedOutEvent fired');
  });

  it('non-production + transport error → local logout proceeds', async () => {
    await primeSession();
    await config().setEndpoint(CUSTOM);
    server.transportError = 'connection refused';
    await UserService.logout();
    assertEquals(config().getToken(), undefined, 'local logout despite transport error');
  });

  it('isEnteProduction() is true only for the production endpoint', async () => {
    await resetAll();
    assertEquals(config().isEnteProduction(), true, 'default endpoint is production');
    await config().setEndpoint(CUSTOM);
    assertEquals(config().isEnteProduction(), false, 'custom endpoint is not production');
    await config().setEndpoint(PRODUCTION);
    assertEquals(config().isEnteProduction(), true, 'explicit production endpoint');
  });

  it('the legacy endpoint is treated as production', async () => {
    await resetAll();
    await config().setEndpoint('https://api.ente.io');
    assertEquals(config().getHttpEndpoint(), PRODUCTION, 'migrated on read, like upstream');
    assertEquals(config().isEnteProduction(), true, 'legacy endpoint counts as production');
    // And it must therefore NOT swallow a server failure.
    await config().setToken('SESSION-TOKEN');
    route('/users/logout', 500, {});
    await assertRejects(() => UserService.logout(), 'legacy endpoint is production');
    assertEquals(config().getToken(), 'SESSION-TOKEN', 'session retained');
  });

  it('SOURCE CONTRACT: the settings UI does not perform a second local logout', async () => {
    const src = readFileSync(join(REPO, 'entry/src/main/ets/pages/SettingsSections.ets'), 'utf8');
    assert(!src.includes('Configuration.instance.logout()'),
      'the UI must not call Configuration.logout() after UserService.logout()');
    assert(src.includes('await UserService.logout()'), 'the UI awaits the orchestration');
  });
});

// ================================================== finding F — persistence

describe('finding F — persistent setters are awaitable and durable', () => {
  it('every persisted setter leaves zero pending writes', async () => {
    await resetAll();
    await config().setEmail('user@example.test');
    await config().setToken('TOKEN');
    await config().setUserId(7);
    await config().setEncryptedToken('ENC');
    await config().setEndpoint(PRODUCTION);
    assertEquals(__pendingWrites(), 0,
      'an awaited setter must have flushed; a non-zero count means the write was fire-and-forget');
  });

  it('the values are actually persisted and re-read after a restart', async () => {
    await resetAll();
    await config().setEmail('user@example.test');
    await config().setToken('TOKEN');
    await config().setUserId(7);
    await config().setEncryptedToken('ENC');
    await config().setEndpoint(CUSTOM);
    await config().setKeyAttributes(KeyAttributes.fromMap(sampleKeyAttributes('restart')));
    await Configuration.instance.init();
    assertEquals(config().getEmail(), 'user@example.test', 'email');
    assertEquals(config().getToken(), 'TOKEN', 'token');
    assertEquals(config().getUserId(), 7, 'userId');
    assertEquals(config().getEncryptedToken(), 'ENC', 'encryptedToken');
    assertEquals(config().getHttpEndpoint(), CUSTOM, 'endpoint');
    assertEquals(config().getKeyAttributes().kekSalt, 'kekSalt-restart', 'keyAttributes');
  });

  it('a fire-and-forget write would be observable as pending', async () => {
    await resetAll();
    // Sanity check on the instrument itself: calling the raw Preferences layer
    // without awaiting must leave the write pending, otherwise the assertion
    // above proves nothing.
    Preferences.setString('probe', 'value');
    assert(__pendingWrites() > 0, 'an un-awaited write must be observable as pending');
    await Preferences.setString('probe', 'value');
    assertEquals(__pendingWrites(), 0, 'awaiting settles it');
  });

  it('clearing a value removes the key and leaves zero pending writes', async () => {
    await resetAll();
    await config().setToken('TOKEN');
    await config().setUserId(7);
    await config().setEncryptedToken('ENC');
    await config().setToken(undefined);
    await config().setUserId(undefined);
    await config().setEncryptedToken(undefined);
    assertEquals(__pendingWrites(), 0, 'removals are awaited too');
    assertEquals(config().getToken(), undefined, 'token cleared');
    assertEquals(config().getUserId(), undefined, 'userId cleared');
    assertEquals(config().getEncryptedToken(), undefined, 'encryptedToken cleared');
    assertEquals(await Preferences.getString('token'), undefined, 'token gone from disk');
  });

  it('saveLoginResponse leaves zero pending writes', async () => {
    await resetAll();
    route('/users/two-factor/verify', 200, {
      id: 5, encryptedToken: 'ENC', keyAttributes: sampleKeyAttributes('pending'),
    });
    const response = await UserService.verifyTwoFactor('s', '123456');
    await UserService.saveLoginResponse(response, config());
    assertEquals(__pendingWrites(), 0, 'login persistence must be fully awaited');
  });

  it('a persistence failure propagates instead of being swallowed', async () => {
    await resetAll();
    // Force the store to reject every write.
    const { preferences } = await import('../shims/kit-arkdata.mjs');
    const store = await preferences.getPreferences({}, 'ente_auth_preferences');
    const original = store.put;
    store.put = async () => {
      throw new Error('disk full');
    };
    try {
      await assertRejects(() => config().setEmail('user@example.test'),
        'a failed persist must reject, not resolve');
      assertEquals(config().getEmail(), undefined,
        'and the cache must not claim a value that was never persisted');
    } finally {
      store.put = original;
    }
  });
});
