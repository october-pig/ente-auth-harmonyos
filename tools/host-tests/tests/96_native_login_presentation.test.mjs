// Executes production UI method bodies, without rendering ArkUI or modelling crypto.
// The existing account suites remain the authority for real service semantics.
import { stripTypeScriptTypes } from 'node:module';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { assert, assertEquals, describe, it } from '../framework.mjs';

const path = 'entry/src/main/ets/pages/OnboardingFlow.ets';
const source = process.env.UI_SOURCE_REF
  ? execFileSync('git', ['show', `${process.env.UI_SOURCE_REF}:${path}`], { encoding: 'utf8' })
  : readFileSync(new URL('../../../' + path, import.meta.url), 'utf8');
function bodyFrom(marker) {
  const start = source.indexOf(marker);
  assert(start >= 0, `missing production method ${marker}`);
  const open = source.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth > 0 && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  return source.slice(start, end);
}
function harness({ fallback = false, fail = false, step = 'complete', gate } = {}) {
  const calls = [], messages = [], routes = [];
  const config = {
    async setEmail(v) { calls.push(['email', v]); if (gate) await gate; },
    getKeyAttributes() { return {}; },
    async decryptSecretsAndGetKeyEncKey(password) { calls.push(['decrypt', password]); },
  };
  const service = {
    async resolveSrpAttributesForLogin(email) { calls.push(['attributes', email]); return fallback ? undefined : {}; },
    async sendOtt(...args) { calls.push(['ott', ...args]); if (fail) throw new Error('synthetic failure'); },
    async loginWithPassword(...args) { calls.push(['password', ...args]); if (fail) throw new Error('synthetic failure'); return { twoFactorSessionID: 'synthetic-session' }; },
    postLoginStep() { return step; },
    async saveLoginResponse() { calls.push(['save']); },
  };
  const bindings = {
    Configuration: { instance: config }, UserService: service,
    Router: { push: (...args) => routes.push(args), goToAuthenticatedRoot: () => routes.push(['home']) },
    S: new Proxy({}, { get: (_, key) => () => key }), Toast: { show: m => messages.push(m) },
    isValidEmail: email => email.includes('@'),
    EmailFlowParam: class { constructor(isSignup, email) { this.isSignup = isSignup; this.email = email; } },
    SrpLoginParam: class { constructor(email, attrs) { this.email = email; this.attrs = attrs; } },
    SessionIDParam: class { constructor(sessionID) { this.sessionID = sessionID; } },
    PostLoginStep: { passkey: 'passkey', twoFactor: 'twoFactor' },
    EventBus: { fire: () => calls.push(['signedIn']) }, Events: { SIGNED_IN: 'signedIn' },
    AuthenticatorService: { instance: { onlineSync: () => calls.push(['sync']) } },
  };
  // Baseline comparison runs the old submit body too: it pushes login-srp,
  // rather than executing a password login, so the new composition assertions fail.
  const helper = source.includes('async function completePasswordLogin(')
    ? stripTypeScriptTypes(bodyFrom('async function completePasswordLogin(')) : '';
  const submit = stripTypeScriptTypes(bodyFrom('private async submit()').replace('private async submit', 'async function submit'));
  const fn = new Function(...Object.keys(bindings), `${helper}\n${submit}\nreturn submit;`)(...Object.values(bindings));
  const state = { email: ' a@example.test ', password: 'synthetic-password', isSignup: false, busy: false };
  return { calls, messages, routes, state, submit: () => fn.call(state) };
}

describe('Native combined login presentation — executable production orchestration', () => {
  it('busy is immediate; repeated taps coalesce while persistence is suspended', async () => {
    let release;
    const h = harness({ gate: new Promise(r => { release = r; }) });
    const first = h.submit();
    assert(h.state.busy);
    await h.submit();
    assertEquals(h.calls.length, 1);
    h.state.email = 'changed@example.test'; h.state.password = 'changed';
    release(); await first;
    assertEquals(h.calls.find(c => c[0] === 'password').slice(1, 3), ['a@example.test', 'synthetic-password']);
    assertEquals(h.state.busy, false);
    assertEquals(h.state.password, '');
  });
  it('direct SRP keeps save/decrypt/event/sync/root ordering', async () => {
    const h = harness(); await h.submit();
    assertEquals(h.calls.map(c => c[0]), ['email', 'attributes', 'password', 'save', 'decrypt', 'signedIn', 'sync']);
    assertEquals(h.routes, [['home']]);
  });
  it('email verification fallback clears the unused password and preserves login OTT', async () => {
    const h = harness({ fallback: true }); await h.submit();
    assertEquals(h.calls.map(c => c[0]), ['email', 'attributes', 'ott']);
    assertEquals(h.calls[2], ['ott', 'a@example.test', 'login', true]);
    assertEquals(h.state.password, '');
    assertEquals(h.routes[0][0], 'login-ott');
    assertEquals(h.routes[0][1].email, 'a@example.test');
  });
  it('signup sends only signup OTT and never submits the password to SRP', async () => {
    const h = harness(); h.state.isSignup = true; await h.submit();
    assertEquals(h.calls.map(c => c[0]), ['email', 'ott']);
    assertEquals(h.calls[1], ['ott', 'a@example.test', 'signup', true]);
    assertEquals(h.state.password, '');
  });
  it('password failure releases busy and leaves editable credentials for retry', async () => {
    const h = harness({ fail: true }); await h.submit();
    assertEquals(h.state.busy, false); assertEquals(h.routes, []);
    assertEquals(h.messages, ['synthetic failure']);
    assertEquals(h.state.password, 'synthetic-password');
  });
  it('2FA routes the returned session without installing credentials', async () => {
    const h = harness({ step: 'twoFactor' }); await h.submit();
    assertEquals(h.routes[0][0], 'two-factor');
    assertEquals(h.routes[0][1].sessionID, 'synthetic-session');
    assert(!h.calls.some(c => c[0] === 'save'));
  });
  it('passkey remains explicitly unsupported, without bypassing it', async () => {
    const h = harness({ step: 'passkey' }); await h.submit();
    assertEquals(h.messages, ['passkeyNotSupported']); assertEquals(h.routes, []);
    assert(!h.calls.some(c => c[0] === 'save'));
  });
  it('invalid email does not persist or send requests', async () => {
    const h = harness(); h.state.email = 'invalid'; await h.submit();
    assertEquals(h.calls, []); assertEquals(h.state.busy, false);
  });
});
