// Real production orchestration, synthetic codes; HTTP/HUKS/RDB remain host models.
import { assert, assertEquals, describe, it } from '../framework.mjs';
import { readFileSync } from 'node:fs';
import { __resetPreferences, __resetRdb } from '../shims/kit-arkdata.mjs';
import { __resetHuks, __huksGenerationCount } from '../shims/kit-huks.mjs';
import { resetHttp, setHttpHandler } from '../shims/kit-network.mjs';
const root = '../gen/entry/src/main/ets/';
const { Preferences } = await import(root + 'storage/Preferences.ts');
const { Configuration } = await import(root + 'account/Configuration.ts');
const { AuthenticatorDB } = await import(root + 'storage/AuthenticatorDB.ts');
const { OfflineAuthenticatorDB } = await import(root + 'storage/OfflineAuthenticatorDB.ts');
const { OfflineMigrationJournal } = await import(root + 'storage/OfflineMigrationJournal.ts');
const { AuthenticatorGateway } = await import(root + 'gateway/AuthenticatorGateway.ts');
const { CodeStore } = await import(root + 'store/CodeStore.ts');
const { AuthenticatorService, AccountMode } = await import(root + 'services/AuthenticatorService.ts');
const { CryptoUtil } = await import(root + 'crypto/CryptoUtil.ts');
const { EventBus, Events } = await import(root + 'events/EventBus.ts');
const config = () => Configuration.instance;
const svc = () => AuthenticatorService.instance;
const migrate = () => CodeStore.instance.importOfflineCodes();
const raw = (account = 'harmony-check', digits = 6) => JSON.stringify(`otpauth://totp/Ente%20Test:${account}?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Ente%20Test&digits=${digits}`);
let remote, posts, now, failDiff, failPost, loseAck, onPost, onDiff;
const reply = (body, status = 200) => ({ responseCode: status, result: JSON.stringify(body) });
async function reset() {
  EventBus.clear(); __resetPreferences(); __resetRdb(); __resetHuks(); resetHttp();
  await Preferences.init({}); await AuthenticatorDB.init({}); await OfflineAuthenticatorDB.init({});
  await config().init(); await config().optForOfflineMode();
  await config().setKey(CryptoUtil.generateKey());
  await config().setAuthSecretKey(CryptoUtil.bin2base64(CryptoUtil.generateKey()));
  await config().setUserId(42); await config().setToken('SYNTHETIC_SESSION');
  remote = []; posts = 0; now = 1700000000000000; failDiff = false; failPost = 0; loseAck = false; onPost = undefined; onDiff = undefined;
  setHttpHandler(async req => {
    const url = new URL(req.url);
    if (url.pathname.endsWith('/diff')) {
      if (onDiff) await onDiff(url);
      if (failDiff) return reply({}, 503);
      const since = Number(url.searchParams.get('sinceTime'));
      const limit = Number(url.searchParams.get('limit'));
      return reply({ diff: remote.filter(e => e.updatedAt > since).slice(0, limit) });
    }
    if (url.pathname === '/authenticator/entity' && req.method === 'POST') {
      posts++;
      if (onPost) await onPost();
      if (failPost === posts) return reply({}, 503);
      const body = JSON.parse(req.extraData);
      const e = { ...body, id: `server-${posts}`, isDeleted: false, createdAt: ++now, updatedAt: now };
      remote.push(e);
      if (loseAck) { loseAck = false; throw new Error('synthetic lost response'); }
      return reply(e);
    }
    throw new Error('unexpected migration endpoint');
  });
}
async function seed(account = 'harmony-check', digits = 6) {
  return svc().addEntry(raw(account, digits), false, AccountMode.offline);
}
async function remoteSeed(account = 'harmony-check', digits = 6) {
  const enc = await CryptoUtil.encryptData(CryptoUtil.strToBin(raw(account, digits)), config().getAuthSecretKey());
  remote.push({ id: `existing-${remote.length}`, encryptedData: CryptoUtil.bin2base64(enc.encryptedData),
    header: CryptoUtil.bin2base64(enc.header), isDeleted: false, createdAt: ++now, updatedAt: now });
}
const offlineCount = async () => (await OfflineAuthenticatorDB.getAll()).length;
async function settle() { await svc().onlineSync(); }

describe('Offline migration safety — production orchestration', () => {
  it('uploads once, confirms server state before source cleanup, and survives re-entry', async () => {
    await reset(); await seed();
    onPost = async () => assertEquals(await offlineCount(), 1, 'source must survive dispatch');
    await migrate(); await settle();
    assertEquals(remote.length, 1); assertEquals(await offlineCount(), 0);
    await config().init(); await migrate(); await settle(); assertEquals(posts, 1);
    assertEquals(__huksGenerationCount('ente_ss_offline_auth_secret_key'), 1);
  });
  it('initial sync failure cannot stage online rows or delete offline rows; retry succeeds', async () => {
    await reset(); await seed(); failDiff = true; await migrate(); await settle();
    assertEquals(await offlineCount(), 1); assertEquals((await AuthenticatorDB.getAll()).length, 0); assertEquals(posts, 0);
    failDiff = false; await migrate(); await settle(); assertEquals(remote.length, 1); assertEquals(await offlineCount(), 0);
  });
  it('overlapping database IDs never overwrite an unrelated online code', async () => {
    await reset(); await remoteSeed('unrelated'); await seed(); await migrate(); await settle();
    const codes = await CodeStore.instance.getAllCodes(AccountMode.online);
    assertEquals(codes.map(c => c.account).sort(), ['harmony-check', 'unrelated']); assertEquals(await offlineCount(), 0);
  });
  it('pinned issuer/account/secret equivalence avoids duplicates even if OTP digits differ', async () => {
    await reset(); await remoteSeed('harmony-check', 8); await seed(); await migrate(); await settle();
    assertEquals(posts, 0); assertEquals(remote.length, 1); assertEquals(await offlineCount(), 0);
  });
  it('two equivalent offline rows produce one remote entry', async () => {
    await reset(); await seed(); await seed(); await migrate(); await settle();
    assertEquals(posts, 1); assertEquals(await offlineCount(), 0);
  });
  it('a failed upload retains its source and never creates an auto-replayed pending online row', async () => {
    await reset(); await seed(); failPost = 1; await migrate(); await settle();
    assertEquals(await offlineCount(), 1); assertEquals(remote.length, 0);
    assertEquals((await AuthenticatorDB.getAll()).length, 0);
    await config().init(); await migrate(); await settle(); assertEquals(posts, 1, 'ambiguous POST is not blindly repeated');
  });
  it('server commit with lost response reconciles on retry without another POST', async () => {
    await reset(); await seed(); loseAck = true; await migrate();
    assertEquals(await offlineCount(), 1);
    await config().init(); await migrate(); await settle();
    assertEquals(posts, 1); assertEquals(remote.length, 1); assertEquals(await offlineCount(), 0);
  });
  it('mixed outcome cleans only the confirmed source and retains the failing and unattempted sources', async () => {
    await reset(); await seed('one'); await seed('two'); await seed('three'); failPost = 2;
    await migrate(); await settle();
    const codes = await CodeStore.instance.getAllCodes(AccountMode.offline);
    assertEquals(codes.map(c => c.account).sort(), ['three', 'two']); assertEquals(remote.length, 1);
  });
  it('reports progress only while an offline source is actually being migrated', async () => {
    await reset();
    let finishEmptySync;
    let emptySyncEntered;
    const emptyEntered = new Promise(resolve => { emptySyncEntered = resolve; });
    const emptyGate = new Promise(resolve => { finishEmptySync = resolve; });
    onDiff = async () => { onDiff = undefined; emptySyncEntered(); await emptyGate; };
    const emptyOperation = migrate();
    try {
      await Promise.race([emptyEntered, emptyOperation.then(() => {
        throw Error('empty-source check did not reach the expected online sync');
      })]);
      assertEquals(CodeStore.instance.isOfflineMigrationRunning(), false,
        'empty-source fallback online sync is not migration progress');
    } finally {
      finishEmptySync();
      await emptyOperation;
    }

    await reset(); await seed();
    const progressEvents = [];
    const onProgress = () => progressEvents.push(CodeStore.instance.isOfflineMigrationRunning());
    EventBus.on(Events.OFFLINE_MIGRATION_CHANGED, onProgress);
    let finishMigrationSync;
    let migrationSyncEntered;
    const migrationEntered = new Promise(resolve => { migrationSyncEntered = resolve; });
    const migrationGate = new Promise(resolve => { finishMigrationSync = resolve; });
    onDiff = async () => { onDiff = undefined; migrationSyncEntered(); await migrationGate; };
    const migrationOperation = migrate();
    try {
      await Promise.race([migrationEntered, migrationOperation.then(() => {
        throw Error('migration did not reach the expected online sync');
      })]);
      assertEquals(CodeStore.instance.isOfflineMigrationRunning(), true,
        'an offline source pending server reconciliation is real migration progress');
    } finally {
      finishMigrationSync();
      await migrationOperation;
      EventBus.off(Events.OFFLINE_MIGRATION_CHANGED, onProgress);
    }
    assertEquals(progressEvents, [true, false], 'listeners receive both start and settlement');
    assertEquals(CodeStore.instance.isOfflineMigrationRunning(), false);
    assertEquals(await offlineCount(), 0);
  });
  it('concurrent Home entries coalesce migration', async () => {
    await reset(); await seed(); await Promise.all([migrate(), migrate(), migrate()]); await settle();
    assertEquals(posts, 1); assertEquals(await offlineCount(), 0);
  });
  it('parse-error source blocks migration visibly without deleting or skipping it', async () => {
    await reset(); await seed(); await svc().addEntry('invalid synthetic data', false, AccountMode.offline);
    const result = await migrate(); await settle();
    assertEquals(await offlineCount(), 2); assertEquals(posts, 0); assertEquals(result, 'unreadable');
  });
  it('source changed during upload is not deleted using its old ID', async () => {
    await reset(); const id = await seed();
    onPost = async () => { await svc().updateEntry(id, raw('edited'), false, AccountMode.offline); };
    await migrate(); await settle();
    assertEquals(await offlineCount(), 1);
    assertEquals((await CodeStore.instance.getAllCodes(AccountMode.offline))[0].account, 'edited');
  });
  it('logout during migration cancels cleanup and preserves decryptable source after restart', async () => {
    await reset(); await seed();
    const progressAcrossLogout = [];
    onPost = async () => {
      progressAcrossLogout.push(CodeStore.instance.isOfflineMigrationRunning());
      await config().logout();
      progressAcrossLogout.push(CodeStore.instance.isOfflineMigrationRunning());
    };
    await migrate();
    assertEquals(progressAcrossLogout, [true, false], 'old account progress must not leak across logout');
    assertEquals(await offlineCount(), 1); assertEquals((await AuthenticatorDB.getAll()).length, 0);
    await config().init(); await config().optForOfflineMode();
    assertEquals((await CodeStore.instance.getAllCodes(AccountMode.offline))[0].hasError, false);
  });
  it('STRUCTURAL CHECK — Home invokes migration and renders retry/status, not device evidence', () => {
    const home = readFileSync(new URL('../../../entry/src/main/ets/pages/HomePage.ets', import.meta.url), 'utf8');
    assert(home.includes('CodeStore.instance.importOfflineCodes()'));
    assert(home.includes('S.offlineMigrationPending()')); assert(home.includes('this.migrateOfflineCodes()'));
  });
  it('logout while preflight pull is waiting must not repopulate the cleared online database', async () => {
    await reset(); await seed(); await remoteSeed('remote-only');
    onDiff = async () => { onDiff = undefined; await config().logout(); };
    await migrate();
    assertEquals((await AuthenticatorDB.getAll()).length, 0);
    assertEquals(await offlineCount(), 1); assertEquals(posts, 0);
  });
  it('unreadable ciphertext is a visible migration failure with all sources retained', async () => {
    await reset(); await seed(); await OfflineAuthenticatorDB.insert('invalid', 'invalid');
    assertEquals(await migrate(), 'unreadable'); assertEquals(await offlineCount(), 2); assertEquals(posts, 0);
  });
  it('surviving offline rows migrate after logout has cleared the mode flag', async () => {
    await reset(); await seed(); await Preferences.remove('has_opted_for_offline_mode');
    await migrate(); assertEquals(await offlineCount(), 0); assertEquals(posts, 1);
  });
  it('full migration scan crosses a tombstone-heavy full page and finds existing equivalent code', async () => {
    await reset(); await seed();
    for (let i = 0; i < 5000; i++) remote.push({id:`deleted-${i}`,isDeleted:true,createdAt:++now,updatedAt:now});
    await remoteSeed();
    for (let i = 0; i < 12 && await offlineCount() > 0; i++) await migrate();
    assertEquals(posts, 0); assertEquals(await offlineCount(), 0);
  });
  it('uncertain journal survives logout and account re-entry without another POST', async () => {
    await reset(); await seed(); failPost = 1; await migrate();
    const master = config().getKey(), auth = config().getAuthSecretKey();
    await config().logout(); await config().init();
    await config().setKey(master); await config().setAuthSecretKey(CryptoUtil.bin2base64(auth));
    await config().setUserId(42); await config().setToken('SYNTHETIC_RELOGIN');
    assertEquals(await migrate(), 'uncertain'); assertEquals(posts, 1); assertEquals(await offlineCount(), 1);
  });
  it('journal failure before dispatch keeps sources and performs no POST', async () => {
    await reset(); await seed();
    const save = OfflineMigrationJournal.recordAttempt;
    OfflineMigrationJournal.recordAttempt = async () => { throw new Error('synthetic disk full'); };
    try { assertEquals(await migrate(), 'retry'); } finally { OfflineMigrationJournal.recordAttempt = save; }
    assertEquals(posts, 0); assertEquals(await offlineCount(), 1);
    await migrate(); assertEquals(posts, 1); assertEquals(await offlineCount(), 0);
  });
  it('journal is scoped to account and endpoint, never prevents a distinct account migration', async () => {
    await reset(); await seed(); failPost = 1; await migrate();
    await config().setUserId(43); await config().setToken('SYNTHETIC_OTHER_ACCOUNT');
    assertEquals(await migrate(), 'complete'); assertEquals(posts, 2); assertEquals(await offlineCount(), 0);
  });
  it('a malformed migration diff response cannot authorize an upload', async () => {
    await reset(); await seed();
    setHttpHandler(async req => {
      const url = new URL(req.url);
      if (url.pathname.endsWith('/diff')) {
        return reply(url.searchParams.get('limit') === '5000' ? {} : { diff: [] });
      }
      posts++; return reply({}, 500);
    });
    assertEquals(await migrate(), 'retry'); assertEquals(posts, 0); assertEquals(await offlineCount(), 1);
  });
  it('unreadable remote records block equivalence decisions and preserve offline source', async () => {
    await reset(); await seed();
    remote.push({id:'damaged',isDeleted:false,encryptedData:'invalid',header:'invalid',createdAt:++now,updatedAt:now});
    assertEquals(await migrate(), 'unreadable'); assertEquals(posts, 0); assertEquals(await offlineCount(), 1);
  });
  it('crash window after durable attempt but before POST fails closed on next entry', async () => {
    await reset(); const id = await seed(); const source = await OfflineAuthenticatorDB.getEntryByID(id);
    const scope = JSON.stringify([config().getHttpEndpoint(), 42]);
    await OfflineMigrationJournal.recordAttempt(scope, id, source.header);
    // Discard service-local state and reopen journal handle without deleting persisted rows.
    CodeStore.instanceValue = undefined; OfflineMigrationJournal.store = undefined;
    await OfflineMigrationJournal.init({}); await config().init();
    assertEquals(await migrate(), 'uncertain'); assertEquals(posts, 0); assertEquals(await offlineCount(), 1);
  });
  it('sync commit already in progress finishes before logout clears online storage', async () => {
    await reset(); await seed(); await remoteSeed('remote-only');
    const original = AuthenticatorDB.insertOrReplace;
    let entered, release;
    const started = new Promise(r => { entered = r; });
    const gate = new Promise(r => { release = r; });
    AuthenticatorDB.insertOrReplace = async entities => { entered(); await gate; await original.call(AuthenticatorDB, entities); };
    try {
      const task = migrate(); await started;
      const logout = config().logout(); release(); await Promise.all([task, logout]);
      assertEquals((await AuthenticatorDB.getAll()).length, 0);
      assertEquals(await Preferences.has('lastEntitySyncTime'), false);
      assertEquals(await offlineCount(), 1); assertEquals(posts, 0);
    } finally { AuthenticatorDB.insertOrReplace = original; }
  });
  it('confirmed upload followed by local cleanup failure is reconciled without another POST', async () => {
    await reset(); await seed(); const original = OfflineAuthenticatorDB.deleteUnchanged;
    OfflineAuthenticatorDB.deleteUnchanged = async () => { throw new Error('synthetic cleanup failure'); };
    try { assertEquals(await migrate(), 'retry'); } finally { OfflineAuthenticatorDB.deleteUnchanged = original; }
    assertEquals(await offlineCount(), 1); assertEquals(posts, 1);
    assertEquals(await migrate(), 'complete'); assertEquals(await offlineCount(), 0); assertEquals(posts, 1);
  });
  it('saturated timestamp page aborts rather than guessing that an equivalent code is absent', async () => {
    await reset(); await seed(); const original = AuthenticatorGateway.getDiff;
    AuthenticatorGateway.getDiff = async (since, limit, strict) => {
      if (!strict) return [[], undefined];
      // A full timestamp bucket cannot be traversed with a timestamp-only cursor.
      return [Array.from({length:5000}, (_,i) => ({id:`tied-${i}`,isDeleted:true,updatedAt:1000})), undefined];
    };
    try { assertEquals(await migrate(), 'retry'); } finally { AuthenticatorGateway.getDiff = original; }
    assertEquals(posts, 0); assertEquals(await offlineCount(), 1);
  });
  it('editing a retained source cannot bypass its uncertain attempt and trigger another POST', async () => {
    await reset(); const id = await seed(); failPost = 1; await migrate();
    await svc().updateEntry(id, raw('edited'), false, AccountMode.offline);
    assertEquals(await migrate(), 'uncertain'); assertEquals(posts, 1); assertEquals(await offlineCount(), 1);
  });
  it('missing offline key does not create or rotate a replacement during migration', async () => {
    await reset(); await seed(); const before = __huksGenerationCount('ente_ss_offline_auth_secret_key');
    config().cachedOfflineSecretKey = undefined;
    assertEquals(await migrate(), 'unreadable'); assertEquals(posts, 0); assertEquals(await offlineCount(), 1);
    assertEquals(__huksGenerationCount('ente_ss_offline_auth_secret_key'), before);
  });
  it('late auth-key creation response cannot restore an online key after logout', async () => {
    await reset(); await seed(); await config().setAuthSecretKey(undefined);
    const getKey = AuthenticatorGateway.getKey, createKey = AuthenticatorGateway.createKey;
    const { AuthenticatorKeyNotFound } = await import(root + 'network/HttpClient.ts');
    AuthenticatorGateway.getKey = async () => { throw new AuthenticatorKeyNotFound(); };
    AuthenticatorGateway.createKey = async () => { await config().logout(); };
    try {
      let rejected = false;
      try { await svc().getOrCreateAuthDataKey(AccountMode.online); } catch { rejected = true; }
      assert(rejected); assertEquals(config().getAuthSecretKey(), undefined); assertEquals(await offlineCount(), 1);
    } finally { AuthenticatorGateway.getKey = getKey; AuthenticatorGateway.createKey = createKey; }
  });
});
