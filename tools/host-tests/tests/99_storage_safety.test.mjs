/** Actual production storage/crypto orchestration, synthetic data only.
 * HUKS/RDB are host models; this never proves device persistence.
 * Authority: pinned Ente 3cc9103a, docs/LOGOUT_STORAGE_AUDIT.md.
 */
import { assert, assertEquals, assertRejects, describe, it } from '../framework.mjs';
import { readFileSync } from 'node:fs';
const { __resetPreferences, __resetRdb, __pendingWrites, preferences } = await import('../shims/kit-arkdata.mjs');
const { __resetHuks, __huksGenerationCount } = await import('../shims/kit-huks.mjs');
const { Preferences } = await import('../gen/entry/src/main/ets/storage/Preferences.ts');
const { SecureStore } = await import('../gen/entry/src/main/ets/storage/SecureStore.ts');
const { Configuration } = await import('../gen/entry/src/main/ets/account/Configuration.ts');
const { AuthenticatorDB } = await import('../gen/entry/src/main/ets/storage/AuthenticatorDB.ts');
const { OfflineAuthenticatorDB } = await import('../gen/entry/src/main/ets/storage/OfflineAuthenticatorDB.ts');
const { AuthenticatorService, AccountMode } = await import('../gen/entry/src/main/ets/services/AuthenticatorService.ts');
const { CryptoUtil } = await import('../gen/entry/src/main/ets/crypto/CryptoUtil.ts');
const { CodeStore } = await import('../gen/entry/src/main/ets/store/CodeStore.ts');
const { EventBus } = await import('../gen/entry/src/main/ets/events/EventBus.ts');
const config = () => Configuration.instance;
const service = () => AuthenticatorService.instance;
const source = (path) => readFileSync(new URL('../../../entry/src/main/ets/' + path, import.meta.url), 'utf8');
async function reset() {
  EventBus.clear();
  __resetPreferences(); __resetRdb(); __resetHuks();
  await Preferences.init({});
  await AuthenticatorDB.init({}); await OfflineAuthenticatorDB.init({});
  await config().init();
}
const fixture = JSON.stringify('otpauth://totp/Ente%20Test:harmony-check?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Ente%20Test');
async function seed() {
  await config().optForOfflineMode();
  await service().addEntry(fixture, false, AccountMode.offline);
}
async function unreadable(expectedRows, expectedSuccess, expectedFailure) {
  let rejected = false;
  try { await service().getEntities(AccountMode.offline); }
  catch (e) {
    rejected = true;
    assertEquals(e.rawRowCount, expectedRows);
    assertEquals(e.decryptSuccessCount, expectedSuccess);
    assertEquals(e.decryptFailureCount, expectedFailure);
    assert(!e.message.includes('otpauth'), 'no payload in the error');
  }
  assert(rejected, 'unreadable rows must not be a successful empty/partial result');
}

describe('X1 — logout owns ordinary preferences, not all persisted secure values', () => {
  it('offline ciphertext remains decryptable after logout, cache reset and offline re-entry', async () => {
    await reset(); await seed();
    assertEquals((await CodeStore.instance.getAllCodes(AccountMode.offline)).length, 1, 'positive control');
    await config().setKey(CryptoUtil.generateKey());
    await config().setSecretKey(CryptoUtil.generateKey());
    await config().setAuthSecretKey(CryptoUtil.bin2base64(CryptoUtil.generateKey()));
    await config().setToken('SYNTHETIC_SESSION');
    // Normal successful logout fixture: acknowledged online row. Pending rows
    // are independently verified to BLOCK logout in 99_review_blockers.
    await AuthenticatorDB.insertOrReplace([{id:'synthetic-synced',encryptedData:'synthetic',header:'synthetic',
      isDeleted:false,createdAt:1,updatedAt:1}]);
    await config().logout();
    assertEquals(await SecureStore.contains('offline_auth_secret_key'), true, 'wrapped offline key survived');
    for (const k of ['key', 'secret_key', 'auth_secret_key']) assertEquals(await SecureStore.contains(k), false);
    assertEquals((await AuthenticatorDB.getAll()).length, 0);
    assertEquals((await OfflineAuthenticatorDB.getAll()).length, 1);
    await config().init();
    assertEquals(await config().hasOptedForOfflineMode(), false, 'upstream removes mode opt-in');
    await config().optForOfflineMode();
    const codes = await CodeStore.instance.getAllCodes(AccountMode.offline);
    assertEquals(codes.length, 1); assertEquals(codes[0].hasError, false);
    assertEquals(__huksGenerationCount('ente_ss_offline_auth_secret_key'), 1, 'no rotation');
    assertEquals(__pendingWrites(), 0);
  });
  it('ordinary clear preserves backup and future secure slots without restore writes', async () => {
    await reset();
    await config().setBackupPassword('synthetic backup password');
    await SecureStore.set('future_secure_slot', 'synthetic value');
    await Preferences.setBool('future_ui_pref', true);
    await Preferences.clear();
    assertEquals(await config().getBackupPassword(), 'synthetic backup password');
    assertEquals(await SecureStore.get('future_secure_slot'), 'synthetic value');
    assertEquals(await Preferences.has('future_ui_pref'), false);
  });
  it('ordinary logout reset follows the audited table, including cached endpoint', async () => {
    await reset();
    const keys = ['email','token','encrypted_token','key_attributes','user_id','endpoint',
      'has_opted_for_offline_mode','lastEntitySyncTime','local_time_offset','should_hide_codes',
      'codeSortKey','should_show_large_icons','should_auto_focus_on_search_bar',
      'should_minimize_on_copy','has_shown_coach_mark_v2','appInstallTime'];
    for (const key of keys) await Preferences.setString(key, 'synthetic');
    await config().setEndpoint('https://synthetic.example.test');
    await config().logout();
    for (const key of keys) assertEquals(await Preferences.has(key), false, key);
    assertEquals(config().getHttpEndpoint(), 'https://api.ente.com');
  });
  it('ordinary clear failure cannot destroy unrelated wrapped values', async () => {
    await reset(); await seed();
    const store = await preferences.getPreferences({}, 'ente_auth_preferences');
    const original = store.delete;
    store.delete = async () => { throw new Error('synthetic delete failure'); };
    try { await assertRejects(() => Preferences.clear()); }
    finally { store.delete = original; }
    assertEquals(await SecureStore.contains('offline_auth_secret_key'), true);
  });
  it('does not manufacture a replacement offline key over existing unreadable rows', async () => {
    await reset(); await seed();
    await Preferences.remove('secstore:offline_auth_secret_key');
    await config().init();
    await assertRejects(() => config().optForOfflineMode());
    assertEquals(await SecureStore.contains('offline_auth_secret_key'), false);
    assertEquals((await OfflineAuthenticatorDB.getAll()).length, 1);
  });
});
describe('X2/X3 — distinguish empty, parse failure and decrypt failure', () => {
  it('an empty database is a successful empty read even without a key', async () => {
    await reset(); assertEquals(await service().getEntities(AccountMode.offline), []);
  });
  it('wrong offline key rejects with row counts and preserves ciphertext', async () => {
    await reset(); await seed();
    await config().setOfflineSecretKey(CryptoUtil.bin2base64(CryptoUtil.generateKey()));
    await unreadable(1, 0, 1);
    assertEquals((await OfflineAuthenticatorDB.getAll()).length, 1);
  });
  it('missing offline key rejects with row counts without generating a key', async () => {
    await reset(); await seed();
    await Preferences.remove('secstore:offline_auth_secret_key'); await config().init();
    await unreadable(1, 0, 1);
    assertEquals(await SecureStore.contains('offline_auth_secret_key'), false);
  });
  it('partial decrypt failures reject complete-code/export reads instead of silently omitting data', async () => {
    await reset(); await seed();
    await OfflineAuthenticatorDB.insert('broken', 'broken');
    await unreadable(2, 1, 1);
    await assertRejects(() => CodeStore.instance.getAllCodes(AccountMode.offline));
    await assertRejects(() => CodeStore.instance.getCodesForExport());
    assertEquals((await OfflineAuthenticatorDB.getAll()).length, 2);
  });
  it('decrypted unsupported plaintext remains a Code.hasError, not a decrypt failure', async () => {
    await reset(); await config().optForOfflineMode();
    await service().addEntry('invalid synthetic plaintext', false, AccountMode.offline);
    const codes = await CodeStore.instance.getAllCodes(AccountMode.offline);
    assertEquals(codes.length, 1); assertEquals(codes[0].hasError, true);
  });
  it('STRUCTURAL CHECK — Home represents read failures before the first-account state', () => {
    const src = source('pages/HomePage.ets');
    assert(src.includes('this.loadError') && src.includes('S.unableToReadCodes()'));
    const body = src.slice(src.indexOf('noCodesAnywhere(): boolean'));
    assert(body.slice(0, 150).includes('this.allCodes.length === 0'));
  });
});
