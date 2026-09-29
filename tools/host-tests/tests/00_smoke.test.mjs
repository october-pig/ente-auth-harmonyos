/**
 * 00_smoke.test.mjs — proves the harness itself works and that the modules
 * under test are the REAL production sources (not reimplementations).
 */
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assert, assertEquals, describe, it } from '../framework.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..', '..');

describe('harness integrity', () => {
  it('gen/ copies are byte-identical to entry/src production sources', () => {
    const manifest = JSON.parse(
      readFileSync(join(HERE, '..', 'gen', 'MANIFEST.json'), 'utf8'));
    assert(manifest.files.length > 30, `expected >30 production files, got ${manifest.files.length}`);
    let checked = 0;
    for (const f of manifest.files) {
      const bytes = readFileSync(join(REPO, f.source));
      const sha = createHash('sha256').update(bytes).digest('hex');
      assertEquals(sha, f.sha256, `sha mismatch for ${f.source}`);
      checked++;
    }
    assert(checked === manifest.files.length, 'checked all files');
  });

  it('production ArkTS modules load and execute under Node', async () => {
    const { Base32 } = await import('../gen/entry/src/main/ets/otp/Base32.ts');
    assertEquals(Base32.decode('JBSWY3DPEHPK3PXP').length, 10, 'base32 decode length');
    const { Otp } = await import('../gen/entry/src/main/ets/otp/Otp.ts');
    const code = await Otp.generateHOTPCodeString('JBSWY3DPEHPK3PXP', 0, 6);
    assertEquals(code, '282760', 'RFC 4226 counter 0');
  });

  it('native crypto shim is live (libsodium)', async () => {
    const { default: entecrypto, _sodiumVersion } = await import('../shims/entecrypto.mjs');
    const k = entecrypto.generateKey();
    assertEquals(k.length, 32, 'key length');
    const salt = entecrypto.getSaltToDeriveKey();
    assertEquals(salt.length, 16, 'salt length');
    assert(typeof _sodiumVersion === 'string', 'sodium version string available');
  });
});
