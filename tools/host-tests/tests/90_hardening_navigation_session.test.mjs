/**
 * 90_hardening_navigation_session.test.mjs — Account and platform regression cases K–Q.
 *
 * WHAT THIS FILE CAN AND CANNOT PROVE
 * ----------------------------------
 * The host harness executes the REAL production sources, but it cannot render
 * ArkUI. So this file contains two clearly separated kinds of check:
 *
 *   BEHAVIOURAL — real execution of production logic:
 *     - `Router`'s root/session transitions (Router is deliberately free of
 *       ArkUI components precisely so this is possible),
 *     - `UserService.resolveSrpAttributesForLogin` (the SRP-vs-OTT decision),
 *     - `UserService.postLoginStep` (the post-login state machine),
 *     - `SecureStore`'s check-then-create race handling,
 *     - the logout request body.
 *
 *   STRUCTURAL CHECK — source assertions over ArkUI `@Component` files that the
 *   harness cannot execute. These prove ONLY that the code has the required
 *   shape. They are NOT device verification, and they are never reported as
 *   DEVICE PASS. Rendering is verified by `assembleHap` (compilation) and
 *   remains DEVICE_REQUIRED for actual behaviour.
 */
import { assert, assertEquals, assertRejects, describe, it } from '../framework.mjs';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..', '..');

const { __resetPreferences, __resetRdb } = await import('../shims/kit-arkdata.mjs');
const { __resetHuks, __huksGenerationCount, huks } = await import('../shims/kit-huks.mjs');
const net = await import('../shims/kit-network.mjs');

const { Preferences } = await import('../gen/entry/src/main/ets/storage/Preferences.ts');
const { Configuration } = await import('../gen/entry/src/main/ets/account/Configuration.ts');
const { UserService, PostLoginStep, SrpSetupNotCompleteError } =
  await import('../gen/entry/src/main/ets/account/UserService.ts');
const { SecureStore } = await import('../gen/entry/src/main/ets/storage/SecureStore.ts');
const { Router } = await import('../gen/entry/src/main/ets/pages/Router.ts');
const { EventBus, Events } = await import('../gen/entry/src/main/ets/events/EventBus.ts');

function source(rel) {
  return readFileSync(join(REPO, rel), 'utf8');
}

/**
 * Extract a method body by name, using brace matching from its first `{`.
 *
 * The marker is matched at the START of a line (ignoring indentation) before
 * falling back to a plain substring search, so a mention of the method inside a
 * doc comment — e.g. a comment that says "whose `build()` returns a Column" —
 * does not hijack the extraction.
 */
function methodBody(src, marker) {
  const escaped = marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const anchored = new RegExp('^[ \\t]*' + escaped, 'm').exec(src);
  const start = anchored ? anchored.index : src.indexOf(marker);
  if (start < 0) return '';
  const open = src.indexOf('{', start);
  if (open < 0) return '';
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth--;
      if (depth === 0) return src.slice(open, i + 1);
    }
  }
  return src.slice(open);
}

// ------------------------------------------------------------- test doubles

/** Duck-typed NavPathStack — the real one is an ArkUI global. */
class FakeNavPathStack {
  constructor() {
    this.entries = [];
  }
  pushPath(info) {
    this.entries.push(info);
  }
  pop() {
    return this.entries.pop();
  }
  size() {
    return this.entries.length;
  }
  clear() {
    this.entries = [];
  }
  names() {
    return this.entries.map((e) => e.name);
  }
  /** Mirrors NavPathStack.getParamByIndex (navigation.d.ts:1113, zero-based). */
  getParamByIndex(index) {
    const e = this.entries[index];
    return e === undefined ? undefined : e.param;
  }
  /** Mirrors NavPathStack.getAllPathName (navigation.d.ts:1099). */
  getAllPathName() {
    return this.entries.map((e) => e.name);
  }
  /** Simulates a SYSTEM back gesture: ArkUI pops without calling Router.back(). */
  systemPop() {
    return this.entries.pop();
  }
}

function makeHost() {
  return {
    root: undefined,
    showAuthenticatedRoot() {
      this.root = 'authenticated';
    },
    showOnboardingRoot() {
      this.root = 'onboarding';
    },
  };
}

// ---------------------------------------------------------- test server

const server = { requests: [], routes: new Map(), transportError: null };

function respond(req) {
  server.requests.push({
    method: req.method,
    url: req.url,
    extraData: req.extraData,
    usingCache: req.usingCache,
  });
  if (server.transportError) throw new Error(server.transportError);
  for (const [match, res] of server.routes) {
    if (req.url.includes(match)) {
      return { responseCode: res.status, result: res.raw ?? JSON.stringify(res.body ?? {}) };
    }
  }
  return { responseCode: 404, result: '{}' };
}

async function resetAll() {
  __resetPreferences();
  __resetRdb();
  __resetHuks();
  net.resetHttp();
  EventBus.clear();
  server.requests = [];
  server.routes = new Map();
  server.transportError = null;
  net.setHttpHandler((req) => respond(req));
  await Preferences.init({});
  await Configuration.instance.init();
}

// ============================================ finding K — root navigation

describe('finding K — the Navigation host is independent of session state', () => {
  it('a push from the onboarding root reaches the stack', () => {
    const stack = new FakeNavPathStack();
    const host = makeHost();
    Router.setStack(stack);
    Router.setRootHost(host);
    host.showOnboardingRoot();

    Router.push('login-email', undefined);
    assertEquals(stack.names(), ['login-email'], 'the pushed route is on the stack');
    assertEquals(host.root, 'onboarding', 'and the root host is still mounted');
    Router.clearRootHost();
  });

  it('every onboarding route is reachable through the one navigation model', () => {
    const stack = new FakeNavPathStack();
    const host = makeHost();
    Router.setStack(stack);
    Router.setRootHost(host);
    host.showOnboardingRoot();
    const routes = ['login-email', 'login-ott', 'password-set', 'password-reenter',
      'recovery-key', 'recover', 'login-srp', 'two-factor'];
    for (const r of routes) {
      Router.push(r, undefined);
    }
    assertEquals(stack.names(), routes, 'all onboarding routes push in order');
    assertEquals(host.root, 'onboarding', 'root host never removed');
    Router.clearRootHost();
  });

  it('root states are NOT push destinations', () => {
    // 'home' and 'onboarding' are root CONTENT, not routes. If a page could push
    // them, a signed-out user could obtain an authenticated page.
    const index = source('entry/src/main/ets/pages/Index.ets');
    const pageMap = methodBody(index, 'PageMap(name: string)');
    assert(!pageMap.includes("name === 'home'"), 'home must not be a pushed route');
    assert(!pageMap.includes("name === 'onboarding'"), 'onboarding must not be a pushed route');
  });

  it('STRUCTURAL CHECK — Navigation is mounted in every ready state', () => {
    const index = source('entry/src/main/ets/pages/Index.ets');
    const build = methodBody(index, 'build()');

    const navAt = build.indexOf('HdsNavigation(this.navStack)');
    assert(navAt >= 0, 'the Navigation host must exist');

    // Both roots must be rendered INSIDE the Navigation, not instead of it.
    const homeAt = build.indexOf('HomePage({');
    const onboardingAt = build.indexOf('OnboardingPage()');
    assert(homeAt > navAt, 'HomePage must be rendered inside Navigation');
    assert(onboardingAt > navAt,
      'OnboardingPage must be rendered inside Navigation — a bare OnboardingPage '
      + 'leaves pushed routes with no host to render into (finding K)');

    // Exactly one Navigation, and it is not behind a session-state branch that
    // could remove it.
    assertEquals(build.split('HdsNavigation(this.navStack)').length - 1, 1,
      'exactly one Navigation host');
    assert(build.includes('if (this.authenticatedRoot)'),
      'the session state selects the root CONTENT');
  });

  it('STRUCTURAL CHECK — Router stays free of ArkUI so this model is testable', () => {
    const router = source('entry/src/main/ets/pages/Router.ets');
    assert(!router.includes('@Component'), 'Router must not declare components');
    assert(!/^\s*(?:@\w+\s*)*struct\s+\w+/m.test(router), 'Router must not declare structs');
    assert(!router.includes('build()'), 'Router must not contain ArkUI builders');
  });

  it('STRUCTURAL CHECK — pushed settings live with the settings sections', () => {
    const sections = source('entry/src/main/ets/pages/SettingsSections.ets');
    assert(sections.includes('export struct SettingsSection'), 'Settings remains an ArkUI component');
    const index = source('entry/src/main/ets/pages/Index.ets');
    assert(index.includes("name === 'settings'"), 'Settings is a real destination');
    assert(index.includes(".hideTitleBar(!name.startsWith('settings'))"), 'Settings uses native navigation titles');
  });
});

// ==================================== finding L — signed-out root transition

describe('finding L — signing out returns to the onboarding root', () => {
  it('goToOnboardingRoot clears the stack and switches the root', () => {
    const stack = new FakeNavPathStack();
    const host = makeHost();
    Router.setStack(stack);
    Router.setRootHost(host);
    host.showAuthenticatedRoot();
    Router.push('setup', undefined);
    Router.push('export', undefined);
    assertEquals(stack.size(), 2, 'authenticated routes pushed');

    Router.goToOnboardingRoot();
    assertEquals(stack.size(), 0,
      'every authenticated route must be discarded so Back cannot return to Home');
    assertEquals(host.root, 'onboarding', 'the onboarding root is shown');
    Router.clearRootHost();
  });

  it('goToAuthenticatedRoot clears the stack and switches the root', () => {
    const stack = new FakeNavPathStack();
    const host = makeHost();
    Router.setStack(stack);
    Router.setRootHost(host);
    host.showOnboardingRoot();
    Router.push('login-email', undefined);
    Router.push('login-ott', undefined);

    Router.goToAuthenticatedRoot();
    assertEquals(stack.size(), 0, 'onboarding routes discarded');
    assertEquals(host.root, 'authenticated', 'the authenticated root is shown');
    Router.clearRootHost();
  });

  it('the param stack is cleared with the route stack', () => {
    const stack = new FakeNavPathStack();
    const host = makeHost();
    Router.setStack(stack);
    Router.setRootHost(host);
    Router.push('login-email', { marker: 1 });
    assert(Router.currentParam() !== undefined, 'param tracked');
    Router.goToOnboardingRoot();
    assertEquals(Router.currentParam(), undefined, 'no stale param survives the transition');
    Router.clearRootHost();
  });

  it('a real logout fires SignedOutEvent — the root transition trigger', async () => {
    await resetAll();
    const seen = [];
    // NOTE: no explicit call type argument here. ArkUI sources use
    // `EventBus.on<object>(...)`, which the ArkTS compiler accepts (see
    // HomePage.ets) but the host type-stripper cannot erase in call position.
    // The production subscription is therefore covered by the structural check
    // below plus assembleHap, not by this execution.
    EventBus.on(Events.SIGNED_OUT, () => seen.push('signed-out'));
    await Configuration.instance.setToken('SESSION-TOKEN');
    server.routes.set('/users/logout', { status: 200, body: {} });

    await UserService.logout();
    assertEquals(seen, ['signed-out'],
      'Configuration.logout() must fire SignedOutEvent so EVERY logout path '
      + 'reaches the onboarding root, not just the Settings one');
    assertEquals(Configuration.instance.hasConfiguredAccount(), false,
      'and the account is no longer configured');
  });

  it('STRUCTURAL CHECK — Index listens for SignedOutEvent', () => {
    const index = source('entry/src/main/ets/pages/Index.ets');
    assert(index.includes('this.sessionController.mount()'), 'Index mounts the production controller');
    assert(index.includes('this.sessionController.unmount()'), 'Index releases its controller');
    const controller = source('entry/src/main/ets/account/RootSessionController.ets');
    assert(controller.includes('Events.SIGNED_OUT'), 'controller observes SignedOutEvent');
    assert(controller.includes('Router.goToOnboardingRoot()'),
      'and turn it into the onboarding root transition');
  });

  it('STRUCTURAL CHECK — the settings logout does not route to the authenticated root', () => {
    const sections = source('entry/src/main/ets/pages/SettingsSections.ets');
    const logout = methodBody(sections, 'private async logout()');
    assert(!logout.includes('goToAuthenticatedRoot'),
      'a successful logout must not return the user to the authenticated root');
    assert(!logout.includes('goToOnboardingRoot'), 'only the root event consumer navigates; no stale UI continuation');
    assert(logout.includes('this.logoutBusy'), 'repeated UI submission is guarded');
  });
});

// ======================================== finding M — SRP-vs-OTT decision

describe('finding M — the SRP-vs-OTT fallback matches upstream exactly', () => {
  const attrs = (over) => ({
    attributes: Object.assign({
      srpUserID: 'user-id', srpSalt: 'c2FsdA==', memLimit: 8192, opsLimit: 1, kekSalt: 'a2Vr',
    }, over),
  });

  it('200 with email MFA disabled and an SRP user id → SRP login', async () => {
    await resetAll();
    server.routes.set('/users/srp/attributes', { status: 200, body: attrs() });
    const a = await UserService.resolveSrpAttributesForLogin('a@example.test');
    assert(a !== undefined, 'SRP login is possible');
    assertEquals(a.srpUserID, 'user-id', 'attributes returned');
  });

  it('200 with email MFA ENABLED → fall back to OTT', async () => {
    await resetAll();
    server.routes.set('/users/srp/attributes', { status: 200, body: attrs({ isEmailMFAEnabled: true }) });
    assertEquals(await UserService.resolveSrpAttributesForLogin('a@example.test'), undefined,
      'email MFA means the OTT flow is required');
  });

  it('200 with an empty srpUserID → fall back to OTT', async () => {
    await resetAll();
    server.routes.set('/users/srp/attributes', { status: 200, body: attrs({ srpUserID: '' }) });
    assertEquals(await UserService.resolveSrpAttributesForLogin('a@example.test'), undefined,
      'an account with no SRP user id cannot complete an SRP exchange');
  });

  it('404 → fall back to OTT', async () => {
    await resetAll();
    server.routes.set('/users/srp/attributes', { status: 404, body: {} });
    assertEquals(await UserService.resolveSrpAttributesForLogin('a@example.test'), undefined,
      'SrpSetupNotCompleteError means the OTT flow');
  });

  it('500 → fall back to OTT without throwing (upstream parity)', async () => {
    await resetAll();
    server.routes.set('/users/srp/attributes', { status: 500, body: {} });
    // Upstream `LoginPage.onPressed` catches everything, logs when it is not
    // SrpSetupNotCompleteError, and falls through to sendOtt. It does NOT
    // rethrow, so this must not either.
    assertEquals(await UserService.resolveSrpAttributesForLogin('a@example.test'), undefined,
      'a server error falls through to OTT exactly as upstream does');
  });

  it('transport error → fall back to OTT without throwing', async () => {
    await resetAll();
    server.transportError = 'network down';
    assertEquals(await UserService.resolveSrpAttributesForLogin('a@example.test'), undefined,
      'a transport failure also falls through to OTT');
  });

  it('a malformed 200 body is not mistaken for "SRP is ready"', async () => {
    await resetAll();
    server.routes.set('/users/srp/attributes', { status: 200, body: { unexpected: true } });
    const a = await UserService.resolveSrpAttributesForLogin('a@example.test');
    assertEquals(a, undefined,
      'a body with no attributes and no srpUserID must not route into SRP login');
  });

  it('a non-JSON 200 body does not crash the decision', async () => {
    await resetAll();
    server.routes.set('/users/srp/attributes', { status: 200, raw: '<html>nope</html>' });
    assertEquals(await UserService.resolveSrpAttributesForLogin('a@example.test'), undefined,
      'unparseable body falls back rather than throwing');
  });

  it('the diagnostic for a non-404 failure is preserved', () => {
    // Upstream logs `severe` for anything that is not SrpSetupNotCompleteError.
    // The previous revision had an empty catch, losing the diagnostic entirely.
    const svc = source('entry/src/main/ets/account/UserService.ets');
    const fn = methodBody(svc, 'resolveSrpAttributesForLogin(');
    assert(fn.includes('instanceof SrpSetupNotCompleteError'),
      'the error must be classified, not swallowed blindly');
    assert(fn.includes('console.warn'), 'non-404 failures must still be logged');
  });

  it('STRUCTURAL CHECK — signup still collects its password only after email verification', () => {
    const flow = source('entry/src/main/ets/pages/OnboardingFlow.ets');
    const page = methodBody(flow, 'export struct EmailEntryPage');
    assert(/if \(!this\.isSignup\) \{[\s\S]*?InputType\.Password/.test(page),
      'the combined password field belongs only to login; signup remains email-first');
    assert(!page.includes('setVolatilePassword'), 'no plaintext password retained');
    assert(page.includes('resolveSrpAttributesForLogin'),
      'the decision is delegated to the service');
  });
});

// ============================================ finding N — SRP → 2FA branch

describe('finding N — SRP login closes the 2FA branch', () => {
  const resp = (over) => Object.assign({
    id: 1, encryptedToken: undefined, token: 'T',
    passkeySessionID: '', twoFactorSessionID: '',
  }, over);

  it('neither extra verification → complete', () => {
    assertEquals(UserService.postLoginStep(resp({})), PostLoginStep.complete, 'complete');
  });

  it('twoFactorSessionID → the 2FA step, session preserved', () => {
    assertEquals(UserService.postLoginStep(resp({ twoFactorSessionID: '2FA-SESSION' })),
      PostLoginStep.twoFactor,
      'an SRP login with 2FA must enter the 2FA flow, not be discarded');
  });

  it('passkeySessionID → the passkey step', () => {
    assertEquals(UserService.postLoginStep(resp({ passkeySessionID: 'PK' })),
      PostLoginStep.passkey, 'passkey stays explicit and unsupported');
  });

  it('passkey wins over two-factor (upstream branch order)', () => {
    // upstream user_service.dart:782-793 checks passkeySessionID first.
    assertEquals(UserService.postLoginStep(resp({ passkeySessionID: 'PK', twoFactorSessionID: '2FA' })),
      PostLoginStep.passkey, 'passkey is checked before two-factor');
  });

  it('a real SRP login response carries the 2FA session id through', async () => {
    await resetAll();
    const { Srp } = await import('../gen/entry/src/main/ets/account/Srp.ts');
    const b64 = (u8) => Buffer.from(u8).toString('base64');
    server.routes.set('/users/srp/attributes', {
      status: 200,
      body: {
        attributes: {
          srpUserID: 'user-id', srpSalt: b64(new Uint8Array(16).fill(1)),
          memLimit: 8192, opsLimit: 1, kekSalt: b64(new Uint8Array(16).fill(2)),
        },
      },
    });
    server.routes.set('/users/srp/create-session', {
      status: 200,
      body: { sessionID: 'sess', srpB: b64(Srp.encodeBigInt(123456789n)) },
    });
    server.routes.set('/users/srp/verify-session', {
      status: 200,
      body: { id: 9, twoFactorSessionID: 'SRP-2FA-SESSION' },
    });
    const attrs = await UserService.getSrpAttributes('a@example.test');
    const response = await UserService.loginWithPassword('a@example.test', 'pw', attrs);
    assertEquals(response.twoFactorSessionID, 'SRP-2FA-SESSION', 'session id parsed');
    assertEquals(UserService.postLoginStep(response), PostLoginStep.twoFactor,
      'and it routes to the 2FA page');
  });

  it('twoFactorSessionIDV2 is used when V1 is absent, on the SRP path too', async () => {
    await resetAll();
    const { Srp } = await import('../gen/entry/src/main/ets/account/Srp.ts');
    const b64 = (u8) => Buffer.from(u8).toString('base64');
    server.routes.set('/users/srp/attributes', {
      status: 200,
      body: {
        attributes: {
          srpUserID: 'user-id', srpSalt: b64(new Uint8Array(16).fill(1)),
          memLimit: 8192, opsLimit: 1, kekSalt: b64(new Uint8Array(16).fill(2)),
        },
      },
    });
    server.routes.set('/users/srp/create-session', {
      status: 200,
      body: { sessionID: 'sess', srpB: b64(Srp.encodeBigInt(123456789n)) },
    });
    server.routes.set('/users/srp/verify-session', {
      status: 200,
      body: { id: 9, twoFactorSessionIDV2: 'V2-SESSION' },
    });
    const attrs = await UserService.getSrpAttributes('a@example.test');
    const response = await UserService.loginWithPassword('a@example.test', 'pw', attrs);
    assertEquals(UserService.postLoginStep(response), PostLoginStep.twoFactor, 'V2 routes to 2FA');
  });

  it('STRUCTURAL CHECK — the SRP page routes to 2FA instead of going back', () => {
    const flow = source('entry/src/main/ets/pages/OnboardingFlow.ets');
    const login = methodBody(flow, 'async function completePasswordLogin(');
    assert(login.includes('postLoginStep'), 'the state machine is consulted');
    assert(login.includes("Router.push('two-factor'"),
      'an SRP login requiring 2FA must enter the 2FA page');
    assert(!login.includes('login with OTT'),
      'it must not tell the user to restart via OTT and discard the SRP session');
    assert(login.includes('passkeyNotSupported'),
      'passkey must remain an explicit, user-visible unsupported branch');
    // The session must not be persisted before the extra verification.
    assert(login.indexOf('saveLoginResponse') > login.indexOf('PostLoginStep.twoFactor'),
      'the session is persisted only on the complete branch');
  });

  it('STRUCTURAL CHECK — 2FA success is not re-enterable via Back', () => {
    const flow = source('entry/src/main/ets/pages/OnboardingFlow.ets');
    const verify = methodBody(flow, 'private async verify2fa()');
    assert(verify.includes("Router.resetTo('password-reenter'"),
      'the consumed 2FA session must be removed from the stack, as upstream does');
  });
});

// ======================================== finding O — dead volatile password

describe('finding O — no plaintext password is retained', () => {
  it('STRUCTURAL CHECK — the API is gone from Configuration', () => {
    const cfg = source('entry/src/main/ets/account/Configuration.ets');
    assert(!cfg.includes('volatilePassword: string'),
      'the field must be removed, not merely unused');
    assert(!cfg.includes('setVolatilePassword('), 'the setter must be removed');
    assert(!cfg.includes('resetVolatilePassword('), 'the reset must be removed');
  });

  it('STRUCTURAL CHECK — no call sites remain anywhere', () => {
    const files = [
      'entry/src/main/ets/pages/OnboardingFlow.ets',
      'entry/src/main/ets/pages/HomePage.ets',
      'entry/src/main/ets/pages/SettingsSections.ets',
      'entry/src/main/ets/pages/Index.ets',
      'entry/src/main/ets/account/UserService.ets',
      'entry/src/main/ets/services/AuthenticatorService.ets',
    ];
    for (const f of files) {
      const src = source(f);
      assert(!src.includes('setVolatilePassword('), `${f} must not set a volatile password`);
      assert(!src.includes('resetVolatilePassword('), `${f} must not reset a volatile password`);
    }
  });

  it('STRUCTURAL CHECK — showPasswordInputs is gone', () => {
    const flow = source('entry/src/main/ets/pages/OnboardingFlow.ets');
    assert(!flow.includes('showPasswordInputs'),
      'the vestigial signup password inputs must be removed');
  });

  it('the signup password is still validated on the page that collects it', () => {
    const flow = source('entry/src/main/ets/pages/OnboardingFlow.ets');
    const setPage = methodBody(flow, 'private async completeSignup()');
    assert(setPage.includes('passwordsDoNotMatch'), 'PasswordSetPage still checks matching');
    assert(setPage.includes('passwordStrengthError'), 'and still checks strength');
  });
});

// ============================================ finding P — logout body parity

describe('finding P — logout sends no request body', () => {
  it('POST /users/logout carries no extraData', async () => {
    await resetAll();
    await Configuration.instance.setToken('SESSION-TOKEN');
    server.routes.set('/users/logout', { status: 200, body: {} });
    await UserService.logout();
    const req = server.requests.find((r) => r.url.includes('/users/logout'));
    assert(req !== undefined, 'logout request issued');
    assertEquals(req.method, 'POST', 'POST');
    assertEquals(req.extraData, undefined,
      'upstream sends no body (`_enteDio.post("/users/logout")`)');
  });

  it('other POSTs still send their body', async () => {
    await resetAll();
    server.routes.set('/users/ott', { status: 200, body: {} });
    await UserService.sendOtt('a@example.test', 'login', true);
    const req = server.requests.find((r) => r.url.includes('/users/ott'));
    assert(req.extraData !== undefined, 'a body-carrying POST is unaffected');
  });
});

// ================================================ finding Q — HUKS race

describe('finding Q — check-then-create race is resolved by re-checking', () => {
  const ALIAS = 'ente_ss_key';

  it('a lost race reuses the winner key instead of failing', async () => {
    await resetAll();
    const original = huks.generateKeyItem;
    let raced = false;
    huks.generateKeyItem = async (alias, options) => {
      if (!raced) {
        raced = true;
        // Model the concurrent winner: the alias now EXISTS...
        await original(alias, options);
        // ...and our own generate then fails.
        const e = new Error('The key with the same alias already exists');
        e.code = 12000017;
        throw e;
      }
      return original(alias, options);
    };
    try {
      await SecureStore.set('key', 'value-after-race');
    } finally {
      huks.generateKeyItem = original;
    }
    assertEquals(__huksGenerationCount(ALIAS), 1, 'exactly one key exists');
    assertEquals(await SecureStore.get('key'), 'value-after-race',
      'the winner key is reused and the value round-trips');
  });

  it('a genuine generation failure still propagates', async () => {
    await resetAll();
    const original = huks.generateKeyItem;
    huks.generateKeyItem = async () => {
      // Fails, and the alias is still absent afterwards.
      const e = new Error('keystore fault');
      e.code = 12000020;
      throw e;
    };
    try {
      await assertRejects(() => SecureStore.set('key', 'v'),
        'a real failure must not be swallowed as a "lost race"');
    } finally {
      huks.generateKeyItem = original;
    }
    assertEquals(__huksGenerationCount(ALIAS), 0, 'nothing was created');
  });

  it('the resolution never inspects the error code', () => {
    const store = source('entry/src/main/ets/storage/SecureStore.ets');
    const fn = methodBody(store, 'async function ensureKey(');
    assert(fn.includes('hasKeyItem'), 'existence is re-checked');
    assert(!/\.code\s*[!=]==?\s*\d/.test(fn),
      'the race must be resolved by re-asking the keystore, never by reading an error code');
    assert(!fn.includes('629'), '629 must not reappear');
  });

  it('the sequential path still generates exactly once', async () => {
    await resetAll();
    await SecureStore.set('key', 'one');
    await SecureStore.set('key', 'two');
    assertEquals(__huksGenerationCount(ALIAS), 1, 'no regeneration');
    assertEquals(await SecureStore.get('key'), 'two', 'latest value');
  });
});
