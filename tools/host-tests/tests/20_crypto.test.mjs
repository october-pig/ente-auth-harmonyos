/**
 * 20_crypto.test.mjs — PRIORITY 2: Ente crypto parity.
 *
 * Strategy (three independent layers, all executed):
 *   1. FIXTURE INTEGRITY — every committed KAT is re-checked from scratch with
 *      libsodium directly, proving the fixture itself is trustworthy. Entries
 *      that carry recorded randomness are re-encrypted; entries whose
 *      randomness is inherent (secretstream header, box_seal ephemeral key)
 *      are verified by decryption — the fixture says which via `verify`.
 *   2. PRODUCTION PARITY — the same inputs are pushed through the REAL
 *      `entry/src/main/ets/crypto/CryptoUtil.ets` and compared byte-for-byte.
 *   3. RECIPE CHECKS — the Ente-specific layering (login-key subkey id/context
 *      and 32->16 truncation, secretstream header/ciphertext split and FINAL
 *      tag, auth-key wrapping, export envelope, full signup/login recipe) is
 *      asserted against a from-spec reference computed in this file.
 *
 * Upstream authority:
 *   .upstream/ente_crypto_dart/lib/src/crypto_util.dart  (@981a9e0f)
 *   .upstream/ente/mobile/packages/configuration/lib/base_configuration.dart
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import {
  assert, assertBytes, assertEquals, assertRejects, assertThrows, describe,
  hex, it, toBase64,
} from '../framework.mjs';

const require = createRequire(import.meta.url);
const sodium = require('libsodium-wrappers-sumo');
await sodium.ready;

const entecrypto = await import('../shims/entecrypto.mjs');
const { CryptoUtil, PW_MEM_LIMIT_SENSITIVE, PW_OPS_LIMIT_SENSITIVE, PW_MEM_LIMIT_MIN, PW_OPS_LIMIT_MAX } =
  await import('../gen/entry/src/main/ets/crypto/CryptoUtil.ts');
const { CryptoBridge } = await import('../gen/entry/src/main/ets/crypto/CryptoBridge.ts');

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = JSON.parse(
  readFileSync(join(HERE, '..', '..', '..', 'entry', 'src', 'test', 'fixtures', 'crypto_vectors.json'), 'utf8'));

/** Fixture fields are self-describing: "hex:<...>" or "base64:<...>". */
function field(v) {
  if (typeof v !== 'string') return v;
  if (v.startsWith('hex:')) return new Uint8Array(Buffer.from(v.slice(4), 'hex'));
  if (v.startsWith('base64:')) return new Uint8Array(Buffer.from(v.slice(7), 'base64'));
  throw new Error(`fixture field is not encoding-tagged: ${v}`);
}

const utf8 = (s) => new Uint8Array(new TextEncoder().encode(s));
const dec = (u8) => new TextDecoder().decode(u8);

// ============================================================ fixture integrity

describe('fixture integrity (recomputed independently with libsodium)', () => {
  it('fixture declares its libsodium version and encoding convention', () => {
    assert(typeof FIXTURES.__format.libsodium === 'string', 'libsodium version recorded');
    assert(FIXTURES.__format.description.includes('hex:'), 'encoding convention documented');
  });

  it('argon2id KAT reproduces (re-encrypt)', () => {
    const f = FIXTURES.argon2id;
    const out = sodium.crypto_pwhash(
      f.outLen, field(f.password), field(f.salt), f.opsLimit, f.memLimit,
      sodium.crypto_pwhash_ALG_ARGON2ID13);
    assertBytes(out, field(f.key), 'argon2id fixture');
  });

  it('crypto_kdf KAT reproduces (ctx "loginctx", subkey id 1)', () => {
    const f = FIXTURES.kdf;
    const k32 = sodium.crypto_kdf_derive_from_key(32, f.subkeyId, f.context, field(f.key));
    assertBytes(k32, field(f.subkey32), 'kdf subkey32');
    assertBytes(k32.slice(0, 16), field(f.subkey16), 'kdf subkey16');
  });

  it('secretbox KAT reproduces (re-encrypt)', () => {
    const f = FIXTURES.secretbox;
    assertBytes(sodium.crypto_secretbox_easy(field(f.message), field(f.nonce), field(f.key)),
      field(f.ct), 'secretbox fixture');
    assertBytes(field(f.message), field(f.messageHex), 'messageHex matches message');
  });

  it('secretstream KAT verifies by decryption (header randomness is recorded)', () => {
    const f = FIXTURES.secretstream;
    assertEquals(f.verify, 'decrypt', 'fixture declares decryption verification');
    const state = sodium.crypto_secretstream_xchacha20poly1305_init_pull(field(f.header), field(f.key));
    const r = sodium.crypto_secretstream_xchacha20poly1305_pull(state, field(f.ct), null);
    assert(r !== false && r !== null, 'pull must succeed');
    assertBytes(r.message, field(f.message), 'secretstream plaintext');
    assertEquals(r.tag, sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL, 'tag is FINAL');
  });

  it('box_seal KAT verifies by decryption (ephemeral key randomness)', () => {
    const f = FIXTURES.boxSeal;
    assertEquals(f.verify, 'decrypt', 'fixture declares decryption verification');
    assertBytes(
      sodium.crypto_box_seal_open(field(f.ct), field(f.publicKey), field(f.secretKey)),
      field(f.message), 'box seal plaintext');
  });

  it('authKeyWrap KAT reproduces (re-encrypt)', () => {
    const f = FIXTURES.authKeyWrap;
    assertBytes(sodium.crypto_secretbox_easy(field(f.dataKey), field(f.nonce), field(f.masterKey)),
      field(f.wrapped), 'auth key wrap fixture');
  });

  it('enteExport fixture decrypts to the recorded plaintext', () => {
    const f = FIXTURES.enteExport;
    const kek = sodium.crypto_pwhash(
      32, utf8(f.password), field(f.kdfParams.salt),
      f.kdfParams.opsLimit, f.kdfParams.memLimit, sodium.crypto_pwhash_ALG_ARGON2ID13);
    // `encryptionNonce` is the secretstream HEADER (encrypted_ente_import.dart:63-67).
    const state = sodium.crypto_secretstream_xchacha20poly1305_init_pull(
      field(f.encryptionNonce), kek);
    const r = sodium.crypto_secretstream_xchacha20poly1305_pull(state, field(f.encryptedData), null);
    assertEquals(dec(r.message), f.plaintext, 'ente export plaintext');
  });

  it('loginFlow fixture is internally consistent', () => {
    const f = FIXTURES.loginFlow;
    const kek = sodium.crypto_pwhash(
      32, utf8(f.password), field(f.kekSalt), f.opsLimit, f.memLimit,
      sodium.crypto_pwhash_ALG_ARGON2ID13);
    assertBytes(kek, field(f.kek), 'kek');
    assertBytes(
      sodium.crypto_secretbox_open_easy(field(f.encryptedKey), field(f.keyDecryptionNonce), kek),
      field(f.masterKey), 'master key unwrap with KEK');
    assertBytes(
      sodium.crypto_secretbox_open_easy(
        field(f.encryptedMasterKeyWithRecoveryKey), field(f.masterKeyDecryptionNonce), field(f.recoveryKeyHex)),
      field(f.masterKey), 'master key unwrap with recovery key');
    assertBytes(
      sodium.crypto_kdf_derive_from_key(32, 1, 'loginctx', kek).slice(0, 16),
      field(f.loginKey), 'login key');
  });
});

// =========================================================== production parity

describe('CryptoUtil parity with the committed KATs (production ArkTS)', () => {
  it('deriveKey matches the argon2id KAT', async () => {
    const f = FIXTURES.argon2id;
    const key = await CryptoUtil.deriveKey(field(f.password), field(f.salt), f.memLimit, f.opsLimit);
    assertBytes(key, field(f.key), 'CryptoUtil.deriveKey argon2id');
    assertEquals(key.length, 32, 'argon2id output length is crypto_secretbox_KEYBYTES (32)');
  });

  it('deriveLoginKey matches the kdf KAT and is truncated to 16 bytes', async () => {
    const f = FIXTURES.kdf;
    const loginKey = await CryptoUtil.deriveLoginKey(field(f.key));
    assertBytes(loginKey, field(f.subkey16), 'deriveLoginKey');
    assertEquals(loginKey.length, 16, 'loginKey is sublist(0,16) of a 32-byte subkey');
  });

  it('decryptSync opens the secretbox KAT', () => {
    const f = FIXTURES.secretbox;
    assertBytes(CryptoUtil.decryptSync(field(f.ct), field(f.key), field(f.nonce)),
      field(f.message), 'secretbox open');
  });

  it('encryptSync/decryptSync round-trip with a 24-byte nonce', () => {
    const key = CryptoUtil.generateKey();
    const msg = utf8('otpauth://totp/Ente:alice@example.com?secret=JBSWY3DPEHPK3PXP');
    const r = CryptoUtil.encryptSync(msg, key);
    assertEquals(r.nonce.length, 24, 'secretbox nonce length');
    assertEquals(r.encryptedData.length, msg.length + 16, 'secretbox MAC is 16 bytes');
    assertBytes(CryptoUtil.decryptSync(r.encryptedData, key, r.nonce), msg, 'round trip');
  });

  it('decryptData opens the secretstream KAT', async () => {
    const f = FIXTURES.secretstream;
    assertBytes(await CryptoUtil.decryptData(field(f.ct), field(f.key), field(f.header)),
      field(f.message), 'secretstream open');
  });

  it('encryptData produces a 24-byte header and msg+17 ciphertext, and round-trips', async () => {
    const key = CryptoUtil.generateKey();
    const msg = utf8('this is a secret otpauth url');
    const r = await CryptoUtil.encryptData(msg, key);
    assertEquals(r.header.length, 24, 'secretstream HEADERBYTES');
    assertEquals(r.encryptedData.length, msg.length + 17, 'secretstream ABYTES');
    assertBytes(await CryptoUtil.decryptData(r.encryptedData, key, r.header), msg, 'round trip');
  });

  it('openSealSync opens the box_seal KAT; sealSync round-trips', () => {
    const f = FIXTURES.boxSeal;
    assertBytes(CryptoUtil.openSealSync(field(f.ct), field(f.publicKey), field(f.secretKey)),
      field(f.message), 'box seal open');
    const kp = CryptoUtil.generateKeyPair();
    assertEquals(kp[0].length, 32, 'box public key length');
    assertEquals(kp[1].length, 32, 'box secret key length');
    const msg = utf8('sealed session token fixture');
    const sealed = CryptoUtil.sealSync(msg, kp[0]);
    assertEquals(sealed.length, msg.length + 48, 'box SEALBYTES');
    assertBytes(CryptoUtil.openSealSync(sealed, kp[0], kp[1]), msg, 'seal round trip');
  });

  it('generateKey is 32 bytes and getSaltToDeriveKey is 16 bytes', () => {
    assertEquals(CryptoUtil.generateKey().length, 32, 'crypto_secretbox_KEYBYTES');
    assertEquals(CryptoUtil.getSaltToDeriveKey().length, 16, 'crypto_pwhash_SALTBYTES');
  });

  it('generateKey produces distinct values', () => {
    const seen = new Set();
    for (let i = 0; i < 64; i++) seen.add(hex(CryptoUtil.generateKey()));
    assertEquals(seen.size, 64, 'keys must not repeat');
  });

  it('full signup->login recipe: password -> KEK -> loginKey -> masterKey', async () => {
    const f = FIXTURES.loginFlow;
    const kek = await CryptoUtil.deriveKey(
      CryptoUtil.utf8Encode(f.password), field(f.kekSalt), f.memLimit, f.opsLimit);
    assertBytes(kek, field(f.kek), 'KEK from password');
    const loginKey = await CryptoUtil.deriveLoginKey(kek);
    assertBytes(loginKey, field(f.loginKey), 'login key');
    const masterKey = CryptoUtil.decryptSync(
      field(f.encryptedKey), kek, field(f.keyDecryptionNonce));
    assertBytes(masterKey, field(f.masterKey), 'master key');
  });
});

// ============================================================== recipe checks

describe('Ente recipe checks against a from-spec reference', () => {
  it('login key = crypto_kdf(32, id=1, ctx="loginctx") then first 16 bytes', async () => {
    const kek = field(FIXTURES.kdf.key);
    const ref16 = sodium.crypto_kdf_derive_from_key(32, 1, 'loginctx', kek).slice(0, 16);
    assertBytes(await CryptoUtil.deriveLoginKey(kek), ref16, 'loginKey recipe');
    const other = sodium.crypto_kdf_derive_from_key(32, 2, 'loginctx', kek).slice(0, 16);
    assert(hex(other) !== hex(ref16), 'subkey id 1 and 2 must differ');
  });

  it('a 32-byte login subkey is NOT the same as the 16-byte truncation', async () => {
    const kek = field(FIXTURES.kdf.key);
    const got = await CryptoUtil.deriveLoginKey(kek);
    assertBytes(got, field(FIXTURES.kdf.subkey16), 'must be the truncated 16-byte value');
    assert(hex(got) !== hex(field(FIXTURES.kdf.subkey32)), 'must not be the full 32-byte subkey');
  });

  it('kdf context must be exactly 8 bytes', () => {
    const kek = CryptoUtil.generateKey();
    assertThrows(() => CryptoBridge.cryptoKdfDeriveFromKey(32, 1, 'loginctx9', kek),
      'a 9-byte context must be rejected');
    assertThrows(() => CryptoBridge.cryptoKdfDeriveFromKey(32, 1, 'loginct', kek),
      'a 7-byte context must be rejected');
    assertEquals(CryptoBridge.cryptoKdfDeriveFromKey(32, 1, 'loginctx', kek).length, 32, '8-byte context ok');
  });

  it('auth key wrapping = secretbox(dataKey, nonce, masterKey) — KAT', () => {
    const f = FIXTURES.authKeyWrap;
    assertBytes(CryptoBridge.secretboxEasy(field(f.dataKey), field(f.nonce), field(f.masterKey)),
      field(f.wrapped), 'auth key wrap');
    assertBytes(CryptoBridge.secretboxOpenEasy(field(f.wrapped), field(f.nonce), field(f.masterKey)),
      field(f.dataKey), 'auth key unwrap');
  });

  it('secretstream tampering is detected', () => {
    const key = CryptoUtil.generateKey();
    const msg = utf8('x');
    const { state, header } = sodium.crypto_secretstream_xchacha20poly1305_init_push(key);
    const ct = sodium.crypto_secretstream_xchacha20poly1305_push(
      state, msg, null, sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
    assertBytes(CryptoBridge.secretstreamDecrypt(key, header, ct), msg, 'FINAL stream opens');
    const bad = new Uint8Array(ct);
    bad[0] ^= 0x01;
    assertThrows(() => CryptoBridge.secretstreamDecrypt(key, header, bad), 'tampered ciphertext must throw');
  });

  it('ente export envelope round-trips through the production code', async () => {
    const f = FIXTURES.enteExport;
    const kek = await CryptoUtil.deriveKey(
      CryptoUtil.utf8Encode(f.password), field(f.kdfParams.salt),
      f.kdfParams.memLimit, f.kdfParams.opsLimit);
    const plain = await CryptoUtil.decryptData(
      field(f.encryptedData), kek, field(f.encryptionNonce));
    assertEquals(dec(plain), f.plaintext, 'decrypted export content');
    assertEquals(f.plaintext.split('\n').length, 3, 'three otpauth lines');
  });
});

// ================================================= deriveSensitiveKey behaviour

describe('deriveSensitiveKey (adaptive Argon2id)', () => {
  it('uses SENSITIVE params first: memLimit 1 GiB, opsLimit 4', () => {
    // ente_crypto_dart crypto_util.dart:714-742. The isLowSpecDevice() branch
    // is iOS-only (device_info.dart:33-44 matches a hardcoded list of old
    // iPhone machine codes and returns false on every other platform), so on
    // HarmonyOS the sensitive values are always the starting point.
    assertEquals(PW_MEM_LIMIT_SENSITIVE, 1073741824, 'memLimitSensitive');
    assertEquals(PW_OPS_LIMIT_SENSITIVE, 4, 'opsLimitSensitive');
    assertEquals(PW_MEM_LIMIT_MIN, 8192, 'memLimitMin');
    assertEquals(PW_OPS_LIMIT_MAX, 4294967295, 'opsLimitMax');
    assertEquals(PW_MEM_LIMIT_SENSITIVE * PW_OPS_LIMIT_SENSITIVE, 4294967296, 'desiredStrength');
  });

  it('falls back by halving memory and doubling ops, keeping mem*ops constant', async () => {
    entecrypto.__setMemLimitCeiling(268435456); // simulate a device that cannot allocate > 256 MiB
    try {
      const salt = field(FIXTURES.argon2id.salt);
      const pw = field(FIXTURES.argon2id.password);
      const r = await CryptoUtil.deriveSensitiveKey(pw, salt);
      assertEquals(r.memLimit, 268435456, 'fell back to 256 MiB');
      assertEquals(r.opsLimit, 16, 'ops doubled twice: 4 -> 8 -> 16');
      assertEquals(r.memLimit * r.opsLimit, 4294967296, 'mem*ops stays constant');
      const direct = await CryptoUtil.deriveKey(pw, salt, r.memLimit, r.opsLimit);
      assertBytes(r.key, direct, 'reported params reproduce the returned key');
    } finally {
      entecrypto.__setMemLimitCeiling(Infinity);
    }
  });

  it('throws when no parameter combination can be satisfied', async () => {
    entecrypto.__setMemLimitCeiling(1024); // below memLimitMin
    try {
      await assertRejects(
        () => CryptoUtil.deriveSensitiveKey(utf8('pw'), new Uint8Array(16)),
        'must reject when every candidate fails');
    } finally {
      entecrypto.__setMemLimitCeiling(Infinity);
    }
  });
});

// ============================================================== argument audit

describe('NAPI contract enforcement (mirrors entecrypto.cpp)', () => {
  it('rejects wrong salt length for cryptoPwHash', () => {
    assertThrows(() => CryptoBridge.cryptoPwHash(utf8('pw'), new Uint8Array(15), 4, 65536),
      'salt must be exactly 16 bytes');
  });

  it('rejects memLimit below the libsodium minimum', () => {
    assertThrows(() => CryptoBridge.cryptoPwHash(utf8('pw'), new Uint8Array(16), 4, 8191),
      'memLimit must be >= 8192');
  });

  it('rejects wrong nonce/key lengths for secretbox', () => {
    const key = CryptoUtil.generateKey();
    const msg = utf8('m');
    assertThrows(() => CryptoBridge.secretboxEasy(msg, new Uint8Array(23), key), 'nonce must be 24 bytes');
    assertThrows(() => CryptoBridge.secretboxEasy(msg, new Uint8Array(24), new Uint8Array(31)), 'key must be 32 bytes');
    assertThrows(() => CryptoBridge.secretboxOpenEasy(new Uint8Array(15), new Uint8Array(24), key),
      'ciphertext shorter than the MAC must be rejected');
  });

  it('handles zero-length messages', () => {
    const key = CryptoUtil.generateKey();
    const empty = new Uint8Array(0);
    const r = CryptoUtil.encryptSync(empty, key);
    assertEquals(r.encryptedData.length, 16, 'empty plaintext -> 16-byte MAC only');
    assertEquals(CryptoUtil.decryptSync(r.encryptedData, key, r.nonce).length, 0, 'empty round trip');
    assertEquals(CryptoBridge.secretboxEasy(empty, r.nonce, key).length, 16, 'secretbox of empty');
  });

  it('secretstream handles a zero-length message', () => {
    const key = CryptoUtil.generateKey();
    const r = CryptoBridge.secretstreamEncrypt(key, new Uint8Array(0));
    assertEquals(r[1].length, 17, 'empty message -> ABYTES only');
    assertEquals(CryptoBridge.secretstreamDecrypt(key, r[0], r[1]).length, 0, 'empty round trip');
  });

  it('handles a Uint8Array view with a non-zero byteOffset', () => {
    // napi_get_typedarray_info returns a pointer already offset into the
    // ArrayBuffer; a subarray must therefore behave identically to a copy.
    const backing = new Uint8Array(64);
    for (let i = 0; i < 64; i++) backing[i] = i;
    const view = backing.subarray(16, 48);
    const copy = Uint8Array.from(view);
    const key = CryptoUtil.generateKey();
    const nonce = new Uint8Array(24);
    assertBytes(CryptoBridge.secretboxEasy(view, nonce, key),
      CryptoBridge.secretboxEasy(copy, nonce, key), 'offset view vs copy');
    assertBytes(CryptoBridge.cryptoKdfDeriveFromKey(32, 1, 'loginctx', view),
      CryptoBridge.cryptoKdfDeriveFromKey(32, 1, 'loginctx', copy), 'kdf offset view vs copy');
  });

  it('rejects a non-Uint8Array argument', () => {
    assertThrows(() => CryptoBridge.secretboxEasy([1, 2, 3], new Uint8Array(24), CryptoUtil.generateKey()),
      'plain array is not a Uint8Array');
  });
});

// ==================================================================== encodings

describe('crypto output encodings (base64 shapes on the wire)', () => {
  it('encryptSync ciphertext is standard base64 with padding when serialised', () => {
    const key = CryptoUtil.generateKey();
    const r = CryptoUtil.encryptSync(utf8('hello ente auth'), key);
    const s = CryptoUtil.bin2base64(r.encryptedData);
    assertEquals(s, toBase64(r.encryptedData), 'standard base64');
    assertEquals(s.length % 4, 0, 'padded to a multiple of 4');
  });

  it('secretstream header is 24 bytes -> 32 base64 chars with no padding', () => {
    const key = CryptoUtil.generateKey();
    const r = CryptoBridge.secretstreamEncrypt(key, utf8('x'));
    assertEquals(CryptoUtil.bin2base64(r[0]).length, 32, '24 bytes -> 32 chars');
    assertEquals(CryptoUtil.bin2base64(r[0]).endsWith('='), false, '24 bytes needs no padding');
  });

  it('a 32-byte value is 44 base64 chars ending in "="', () => {
    const s = CryptoUtil.bin2base64(CryptoUtil.generateKey());
    assertEquals(s.length, 44, '32 bytes -> 44 chars');
    assert(s.endsWith('='), 'one padding char');
  });
});
