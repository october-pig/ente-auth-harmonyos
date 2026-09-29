/**
 * 60_hardening_secure_storage.test.mjs — POST_MIGRATION_AUDIT finding A.
 *
 * Executes the REAL production module
 *   entry/src/main/ets/storage/SecureStore.ets
 * over the host HUKS model, and asserts the properties the fix exists to
 * guarantee:
 *
 *   - the alias for a logical key is generated EXACTLY ONCE, no matter how many
 *     times `SecureStore.set()` is called for it (no silent key rotation);
 *   - `get()` after a second `set()` returns the NEW value (so reuse really did
 *     reuse the same key rather than generating a fresh one);
 *   - the alias survives a simulated app/storage restart;
 *   - a tampered ciphertext still fails authentication;
 *   - `delete()` removes BOTH the ciphertext and the alias, and is idempotent;
 *   - production no longer depends on any duplicate-`generateKeyItem` behaviour.
 *
 * The last point is enforced structurally, not by convention: the host HUKS model
 * now throws the DOCUMENTED `12000017` (HUKS_ERR_CODE_KEY_ALREADY_EXIST) for a
 * pre-existing alias, and `generateKeyItem` on an existing alias is an error with
 * no documented idempotent success path. An implementation that relied on
 * duplicate-generate therefore FAILS these tests rather than passing them.
 *
 * Authority: `@ohos.security.huks.d.ts` (DevEco SDK 26.0.0.105) + HarmonyOS
 * Developer Knowledge MCP (`js-apis-huks`, `errorcode-huks`,
 * `faqs-universal-keystore-12`). See docs/TESTING.md finding A.
 */
import { assert, assertEquals, describe, it } from '../framework.mjs';

const { __resetPreferences } = await import('../shims/kit-arkdata.mjs');
const {
  __resetHuks, __huksAliases, __huksGenerationCount, __huksTotalGenerations,
  huks, HuksExceptionErrCode,
} = await import('../shims/kit-huks.mjs');

const { Preferences } = await import('../gen/entry/src/main/ets/storage/Preferences.ts');
const { SecureStore } = await import('../gen/entry/src/main/ets/storage/SecureStore.ts');
const { CryptoUtil } = await import('../gen/entry/src/main/ets/crypto/CryptoUtil.ts');

const ALIAS = 'ente_ss_key';

async function resetAll() {
  __resetPreferences();
  __resetHuks();
  await Preferences.init({});
}

describe('finding A — HUKS key alias lifecycle', () => {
  it('the first set() generates the alias exactly once', async () => {
    await resetAll();
    await SecureStore.set('key', 'bWFzdGVyLWtleQ==');
    assertEquals(__huksGenerationCount(ALIAS), 1, 'one generation');
    assertEquals(__huksAliases().includes(ALIAS), true, 'alias exists');
  });

  it('a second set() on the same logical key does NOT regenerate the key', async () => {
    await resetAll();
    await SecureStore.set('key', 'first-value');
    await SecureStore.set('key', 'second-value');
    await SecureStore.set('key', 'third-value');
    // The whole point: repeated writes must never rotate the HUKS key that
    // protects this logical slot.
    assertEquals(__huksGenerationCount(ALIAS), 1,
      'the alias must be generated once and reused, not regenerated per write');
    assertEquals(__huksTotalGenerations(), 1, 'no other alias generated either');
  });

  it('the value read back after repeated set() calls is the latest value', async () => {
    await resetAll();
    await SecureStore.set('key', 'first-value');
    await SecureStore.set('key', 'second-value');
    assertEquals(await SecureStore.get('key'), 'second-value',
      'reuse must decrypt correctly under the same key');
  });

  it('the alias remains usable after a simulated app restart', async () => {
    await resetAll();
    await SecureStore.set('key', 'value-before-restart');
    // Simulate a restart: production re-reads storage from scratch. The HUKS
    // keystore itself is process-external, so the alias must still be there and
    // must not be regenerated.
    await Preferences.init({});
    assertEquals(await SecureStore.get('key'), 'value-before-restart', 'still readable');
    await SecureStore.set('key', 'value-after-restart');
    assertEquals(__huksGenerationCount(ALIAS), 1, 'no regeneration across restart');
    assertEquals(await SecureStore.get('key'), 'value-after-restart', 'rewrite works');
  });

  it('a tampered ciphertext still fails authentication', async () => {
    await resetAll();
    await SecureStore.set('key', 'hello');
    const blob = CryptoUtil.base642bin(await Preferences.getString('secstore:key'));
    blob[blob.length - 1] ^= 0x01;
    await Preferences.setString('secstore:key', CryptoUtil.bin2base64(blob));
    let threw = false;
    try {
      await SecureStore.get('key');
    } catch (e) {
      threw = true;
    }
    assert(threw, 'GCM must reject a tampered ciphertext');
  });

  it('delete() removes both the ciphertext and the HUKS alias', async () => {
    await resetAll();
    await SecureStore.set('key', 'v');
    await SecureStore.delete('key');
    assertEquals(await SecureStore.get('key'), undefined, 'ciphertext gone');
    assertEquals(await SecureStore.contains('key'), false, 'contains false');
    assertEquals(__huksAliases().includes(ALIAS), false, 'HUKS alias deleted');
  });

  it('delete() on an absent key is idempotent and does not throw', async () => {
    await resetAll();
    await SecureStore.delete('never-set');
    await SecureStore.delete('never-set');
    assertEquals(await SecureStore.get('never-set'), undefined, 'still absent');
  });

  it('each logical key gets its own alias and its own generation', async () => {
    await resetAll();
    await SecureStore.set('key', 'a');
    await SecureStore.set('secret_key', 'b');
    await SecureStore.set('auth_secret_key', 'c');
    assertEquals(__huksGenerationCount('ente_ss_key'), 1, 'key alias');
    assertEquals(__huksGenerationCount('ente_ss_secret_key'), 1, 'secret_key alias');
    assertEquals(__huksGenerationCount('ente_ss_auth_secret_key'), 1, 'auth_secret_key alias');
    assertEquals(__huksTotalGenerations(), 3, 'exactly three generations');
  });

  it('an alias created by an earlier process is reused, not regenerated', async () => {
    await resetAll();
    // Pre-seed the keystore directly, as if a previous run had created the key,
    // then write through production. This is the case the old 629-guard was
    // supposed to handle and did not.
    await huks.generateKeyItem(ALIAS, { properties: [] });
    assertEquals(__huksGenerationCount(ALIAS), 1, 'pre-seeded once');
    await SecureStore.set('key', 'written-by-a-later-run');
    assertEquals(__huksGenerationCount(ALIAS), 1,
      'production must reuse a pre-existing alias, not attempt to regenerate it');
    assertEquals(await SecureStore.get('key'), 'written-by-a-later-run', 'round trip');
  });

  it('the host HUKS model throws the documented duplicate-alias code, not 629', async () => {
    await resetAll();
    await huks.generateKeyItem(ALIAS, { properties: [] });
    let code = undefined;
    try {
      await huks.generateKeyItem(ALIAS, { properties: [] });
    } catch (e) {
      code = e.code;
    }
    assertEquals(code, HuksExceptionErrCode.HUKS_ERR_CODE_KEY_ALREADY_EXIST,
      'duplicate generate must report 12000017');
    assertEquals(code, 12000017, 'and the literal documented value');
    assert(code !== 629, '629 is not a HUKS error code and must not be modelled');
  });

  it('hasKeyItem reports absence as false (the API production uses)', async () => {
    await resetAll();
    assertEquals(await huks.hasKeyItem('ente_ss_absent', { properties: [] }), false,
      'absent -> false, not a rejection');
    await huks.generateKeyItem('ente_ss_absent', { properties: [] });
    assertEquals(await huks.hasKeyItem('ente_ss_absent', { properties: [] }), true,
      'present -> true');
  });

  it('SecureStore writes no plaintext into preferences', async () => {
    await resetAll();
    const secret = 'SUPER-SECRET-MASTER-KEY-VALUE';
    await SecureStore.set('key', secret);
    const stored = await Preferences.getString('secstore:key');
    assert(stored !== undefined, 'stored');
    assert(!stored.includes(secret), 'the raw secret must not appear in preferences');
  });
});
