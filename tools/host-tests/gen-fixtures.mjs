/**
 * gen-fixtures.mjs — regenerate `entry/src/test/fixtures/crypto_vectors.json`.
 *
 * The first pass shipped this fixture file with NO generator (the script that
 * produced it was never committed), and two of its entries were unusable as
 * known-answer tests because the randomness was not recorded:
 *
 *   - `secretstream`: the stream HEADER is random and drives the ciphertext,
 *     so the recorded `ct` cannot be reproduced by re-encrypting. It IS a
 *     valid KAT when verified by DECRYPTION with the recorded header.
 *   - `boxSeal`: crypto_box_seal picks an ephemeral keypair, so the ciphertext
 *     is likewise unreproducible. Also valid only as a decryption KAT.
 *
 * This generator records every random input it uses, so each entry is either
 * (a) reproducible by re-encryption, or (b) verifiable by decryption — and the
 * file says which. Encoding is documented per field: `hex:` or `base64:`.
 *
 * Run:  node gen-fixtures.mjs
 */
import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const sodium = require('libsodium-wrappers-sumo');
await sodium.ready;

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, '..', '..', 'entry', 'src', 'test', 'fixtures', 'crypto_vectors.json');

const hex = (u8) => Buffer.from(u8).toString('hex');
const b64 = (u8) => Buffer.from(u8).toString('base64');
const fromHex = (s) => new Uint8Array(Buffer.from(s, 'hex'));
const utf8 = (s) => new Uint8Array(Buffer.from(s, 'utf8'));

// Deterministic pseudo-randomness so regeneration is reproducible.
let seed = 0x9e3779b9;
function rnd(n) {
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    seed = (seed * 1103515245 + 12345) >>> 0;
    out[i] = (seed >>> 16) & 0xff;
  }
  return out;
}

const fixture = {
  __format: {
    description:
      'Ente crypto known-answer tests. Every field is prefixed by its encoding: ' +
      '"hex:" or "base64:". `verify` states how the entry must be checked.',
    libsodium: sodium.SODIUM_VERSION_STRING ?? 'unknown',
    upstream: 'ente_crypto_dart@981a9e0f4a227023991af3332ef0e6ab6d14a1c2',
  },

  // ---------------------------------------------------------------- argon2id
  argon2id: (() => {
    const password = utf8('correct horse battery staple');
    const salt = fromHex('e028ec4c462187ab08d8902131a04fc9');
    const memLimit = 268435456;
    const opsLimit = 4;
    const key = sodium.crypto_pwhash(
      32, password, salt, opsLimit, memLimit, sodium.crypto_pwhash_ALG_ARGON2ID13);
    return {
      verify: 're-encrypt',
      algorithm: 'crypto_pwhash_ALG_ARGON2ID13',
      outLen: 32,
      password: `base64:${b64(password)}`,
      salt: `hex:${hex(salt)}`,
      memLimit,
      opsLimit,
      key: `hex:${hex(key)}`,
    };
  })(),

  // -------------------------------------------------------------------- kdf
  kdf: (() => {
    const key = fromHex('87b920448e0236d8a7e415fa3222e9fee9768292e6be6834d11616a6b0ea9323');
    const subkey32 = sodium.crypto_kdf_derive_from_key(32, 1, 'loginctx', key);
    return {
      verify: 're-derive',
      recipe: 'crypto_kdf_derive_from_key(subkeyLen, subkeyId=1, context="loginctx", key)',
      key: `hex:${hex(key)}`,
      subkeyId: 1,
      context: 'loginctx',
      subkey32: `hex:${hex(subkey32)}`,
      subkey16: `hex:${hex(subkey32.slice(0, 16))}`,
      loginKeyNote: 'deriveLoginKey returns subkey32.sublist(0, 16)',
    };
  })(),

  // -------------------------------------------------------------- secretbox
  secretbox: (() => {
    const key = fromHex('0746f942a416b60b4e5181185c5755583a31acab8033be641bd1a7b00aebc833');
    const nonce = fromHex('38b6f7fb6f54ec2269d72aa43c0c4c1bd63d64c5465f1a17');
    const message = utf8('hello ente auth');
    const ct = sodium.crypto_secretbox_easy(message, nonce, key);
    return {
      verify: 're-encrypt',
      algorithm: 'crypto_secretbox_easy (XSalsa20-Poly1305)',
      key: `hex:${hex(key)}`,
      nonce: `hex:${hex(nonce)}`,
      message: `base64:${b64(message)}`,
      messageHex: `hex:${hex(message)}`,
      ct: `hex:${hex(ct)}`,
    };
  })(),

  // ----------------------------------------------------------- secretstream
  secretstream: (() => {
    const key = fromHex('2c457782599c722ab0e703f4cf7fbb25fabee198bb3f7d4b45f17844bc17a380');
    const message = utf8('this is a secret otpauth url');
    const { state, header } = sodium.crypto_secretstream_xchacha20poly1305_init_push(key);
    const ct = sodium.crypto_secretstream_xchacha20poly1305_push(
      state, message, null, sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
    return {
      verify: 'decrypt',
      note: 'The stream header is random, so the ciphertext is NOT reproducible ' +
        'by re-encryption. Verify by decrypting with the recorded header+key.',
      algorithm: 'crypto_secretstream_xchacha20poly1305, single TAG_FINAL message',
      key: `hex:${hex(key)}`,
      header: `hex:${hex(header)}`,
      message: `base64:${b64(message)}`,
      ct: `hex:${hex(ct)}`,
      tag: 'FINAL',
    };
  })(),

  // ---------------------------------------------------------------- boxSeal
  boxSeal: (() => {
    const kp = sodium.crypto_box_keypair();
    const message = utf8('sealed session token fixture');
    const ct = sodium.crypto_box_seal(message, kp.publicKey);
    return {
      verify: 'decrypt',
      note: 'crypto_box_seal uses an ephemeral keypair, so the ciphertext is NOT ' +
        'reproducible. Verify by opening with the recorded keypair.',
      algorithm: 'crypto_box_seal (X25519 + XSalsa20-Poly1305)',
      publicKey: `hex:${hex(kp.publicKey)}`,
      secretKey: `hex:${hex(kp.privateKey)}`,
      message: `base64:${b64(message)}`,
      ct: `hex:${hex(ct)}`,
    };
  })(),

  // ------------------------------------------------------------- enteExport
  enteExport: (() => {
    const password = utf8('export-password');
    const plaintext = [
      'otpauth://totp/GitHub:octocat@example.com?algorithm=SHA1&digits=6&issuer=GitHub&period=30&secret=JBSWY3DPEHPK3PXP',
      'otpauth://totp/Ente:alice@example.com?algorithm=SHA256&digits=6&issuer=Ente&period=30&secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
      'otpauth://hotp/VPN:bob@example.com?algorithm=SHA512&digits=8&issuer=VPN&period=30&secret=KRSXG5CTMVRXEZLU&counter=7',
    ].join('\n');
    const salt = rnd(16);
    const memLimit = 268435456;
    const opsLimit = 4;
    const key = sodium.crypto_pwhash(
      32, password, salt, opsLimit, memLimit, sodium.crypto_pwhash_ALG_ARGON2ID13);
    const { state, header } = sodium.crypto_secretstream_xchacha20poly1305_init_push(key);
    const ct = sodium.crypto_secretstream_xchacha20poly1305_push(
      state, utf8(plaintext), null, sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
    return {
      verify: 'decrypt',
      note: 'EnteAuthExport v1 envelope. `encryptionNonce` is the secretstream ' +
        'HEADER (24 bytes), not a secretbox nonce. See encrypted_ente_import.dart:63-67.',
      version: 1,
      password: 'export-password',
      plaintext,
      kdfParams: {
        memLimit,
        opsLimit,
        salt: `base64:${b64(salt)}`,
      },
      encryptedData: `base64:${b64(ct)}`,
      encryptionNonce: `base64:${b64(header)}`,
    };
  })(),

  // ------------------------------------------------------------ authKeyWrap
  authKeyWrap: (() => {
    const dataKey = fromHex('dda8a92a944f254c6abb7daecb806abacdb4bfe5c726e77349bff51de0dba902');
    const masterKey = fromHex('beb531399222f461f22610e61e1ef10bd90ddd0b47350c95ae6f12330aa2533d');
    const nonce = fromHex('f8ba2ea68fdfcd942c67eab3f4ac3d6f315cbf8ac17aa559');
    const wrapped = sodium.crypto_secretbox_easy(dataKey, nonce, masterKey);
    return {
      verify: 're-encrypt',
      recipe: 'CryptoUtil.encryptSync(dataKey, masterKey) — the AuthKey header is the nonce',
      dataKey: `hex:${hex(dataKey)}`,
      masterKey: `hex:${hex(masterKey)}`,
      nonce: `hex:${hex(nonce)}`,
      wrapped: `hex:${hex(wrapped)}`,
    };
  })(),

  // -------------------------------------------------------------- login flow
  loginFlow: (() => {
    // Full signup->login recipe: master/recovery key wrapping + KEK derivation.
    const masterKey = rnd(32);
    const recoveryKey = rnd(32);
    const encMaster = (() => {
      const nonce = rnd(24);
      return { nonce, ct: sodium.crypto_secretbox_easy(masterKey, nonce, recoveryKey) };
    })();
    const encRecovery = (() => {
      const nonce = rnd(24);
      return { nonce, ct: sodium.crypto_secretbox_easy(recoveryKey, nonce, masterKey) };
    })();
    const kekSalt = rnd(16);
    const kek = sodium.crypto_pwhash(
      32, utf8('password123'), kekSalt, 4, 268435456, sodium.crypto_pwhash_ALG_ARGON2ID13);
    const encKeyData = (() => {
      const nonce = rnd(24);
      return { nonce, ct: sodium.crypto_secretbox_easy(masterKey, nonce, kek) };
    })();
    const loginKey = sodium.crypto_kdf_derive_from_key(32, 1, 'loginctx', kek).slice(0, 16);
    return {
      verify: 're-derive',
      note: 'Mirrors BaseConfiguration.generateKey (base_configuration.dart:114-160).',
      password: 'password123',
      masterKey: `hex:${hex(masterKey)}`,
      recoveryKeyHex: `hex:${hex(recoveryKey)}`,
      kekSalt: `base64:${b64(kekSalt)}`,
      memLimit: 268435456,
      opsLimit: 4,
      kek: `hex:${hex(kek)}`,
      loginKey: `hex:${hex(loginKey)}`,
      encryptedMasterKeyWithRecoveryKey: `base64:${b64(encMaster.ct)}`,
      masterKeyDecryptionNonce: `base64:${b64(encMaster.nonce)}`,
      recoveryKeyEncryptedWithMasterKey: `base64:${b64(encRecovery.ct)}`,
      recoveryKeyDecryptionNonce: `base64:${b64(encRecovery.nonce)}`,
      encryptedKey: `base64:${b64(encKeyData.ct)}`,
      keyDecryptionNonce: `base64:${b64(encKeyData.nonce)}`,
    };
  })(),
};

writeFileSync(OUT, JSON.stringify(fixture, null, 2) + '\n', 'utf8');
console.log(`[gen-fixtures] wrote ${OUT}`);

// Also emit the ArkTS embedding. The first pass hand-wrote this file with the
// JSON pasted raw into a double-quoted string literal (unescaped quotes and
// newlines), which is not valid ArkTS at all. Emit a properly escaped literal.
const ETS_OUT = join(HERE, '..', '..', 'entry', 'src', 'test', 'FixturesData.ets');
const jsonOneLine = JSON.stringify(fixture);
const escaped = jsonOneLine.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
const ets = `/**
 * Auto-generated by tools/host-tests/gen-fixtures.mjs — DO NOT EDIT BY HAND.
 *
 * Regenerate with:  node tools/host-tests/gen-fixtures.mjs
 *
 * The JSON below is embedded as a single properly-escaped ArkTS string
 * literal. (The first-pass version pasted the raw multi-line JSON into a
 * double-quoted literal, which does not compile.)
 */
export const CRYPTO_FIXTURES_JSON: string =
  "${escaped}";
`;
writeFileSync(ETS_OUT, ets, 'utf8');
console.log(`[gen-fixtures] wrote ${ETS_OUT}`);
console.log(`[gen-fixtures] libsodium ${fixture.__format.libsodium}`);
