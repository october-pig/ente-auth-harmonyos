/**
 * entecrypto.mjs — host stand-in for the `libentecrypto.so` NAPI module.
 *
 * This shim reproduces the *contract* of `entry/src/main/cpp/entecrypto.cpp`
 * exactly: same 12 exported functions, same argument order, same validation,
 * same error messages, same return shapes. The primitive implementations come
 * from `libsodium-wrappers-sumo` (the same libsodium C library upstream's
 * `sodium_libs` uses, compiled to WASM instead of aarch64).
 *
 * WHAT THIS PROVES: the ArkTS call sites, argument order, lengths, encodings
 * and the Ente recipes layered on top are correct, and that the recipes agree
 * byte-for-byte with upstream.
 * WHAT THIS DOES NOT PROVE: that the compiled aarch64 libentecrypto.so behaves
 * identically on device. That remains DEVICE_REQUIRED (see ACCEPTANCE_MATRIX).
 */
import { createRequire } from 'node:module';

// libsodium-wrappers-sumo@0.7.16 ships a broken ESM entry (it imports
// 'libsodium-sumo' through a non-existent relative path). Load the CommonJS
// build instead — same code, same WASM.
const require = createRequire(import.meta.url);
const sodium = require('libsodium-wrappers-sumo');

await sodium.ready;

// ---- constants mirrored from libsodium.h (same values used by entecrypto.cpp)
const KEY_BYTES = 32;
const NONCE_BYTES = 24;
const SALT_BYTES = 16;
const STREAM_HEADER_BYTES = 24;
const STREAM_A_BYTES = 17;
const BOX_PUBLICKEY_BYTES = 32;
const BOX_SECRETKEY_BYTES = 32;
const BOX_SEAL_BYTES = 48;
const KDF_CONTEXT_BYTES = 8;
const KDF_KEY_BYTES = 32;
const KDF_BYTES_MIN = 16;
const KDF_BYTES_MAX = 64;

function expectU8(v, what) {
  if (!(v instanceof Uint8Array)) {
    throw new Error(`TypeError: expected Uint8Array (${what})`);
  }
  return v;
}

function expectU32(v) {
  if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v > 0xffffffff) {
    throw new Error('TypeError: expected unsigned integer');
  }
  return v >>> 0;
}

// ---------------- random ----------------

function randomBytes(len) {
  const n = expectU32(len);
  if (n > 16 * 1024 * 1024) throw new Error('RangeError: len too large');
  return new Uint8Array(sodium.randombytes_buf(n));
}

function generateKey() {
  return new Uint8Array(sodium.randombytes_buf(KEY_BYTES));
}

function getSaltToDeriveKey() {
  return new Uint8Array(sodium.randombytes_buf(SALT_BYTES));
}

// ---------------- argon2id ----------------

/**
 * Test hook: simulate a device whose argon2id allocation fails above a given
 * memory limit (the WASM heap is far smaller than a phone's, and real devices
 * can OOM at 1 GiB). `crypto_pwhash` returns failure above the ceiling, which
 * is exactly how libsodium signals OOM. Set to Infinity for real behaviour.
 */
let memLimitCeiling = Infinity;
export function __setMemLimitCeiling(n) {
  memLimitCeiling = n;
}
export function __getMemLimitCeiling() {
  return memLimitCeiling;
}

function cryptoPwHash(password, salt, opsLimit, memLimit) {
  const pw = expectU8(password, 'password');
  const s = expectU8(salt, 'salt');
  const ops = expectU32(opsLimit);
  const mem = expectU32(memLimit);
  if (s.length !== SALT_BYTES) throw new Error('Invalid salt length');
  // entecrypto.cpp checks `memLimit < 8192 || memLimit > 4398046511104ULL`;
  // the upper bound is dead code for a uint32_t argument (the compiler warns),
  // so only the lower bound is effective. Mirrored faithfully.
  if (mem < 8192) throw new Error('Invalid memLimit');
  if (ops < 1) throw new Error('Invalid opsLimit');
  if (mem > memLimitCeiling) throw new Error('crypto_pwhash failed (out of memory)');
  try {
    const out = sodium.crypto_pwhash(
      KEY_BYTES, pw, s, ops, mem, sodium.crypto_pwhash_ALG_ARGON2ID13);
    return new Uint8Array(out);
  } catch (e) {
    throw new Error('crypto_pwhash failed (out of memory)');
  }
}

// ---------------- kdf ----------------

function cryptoKdfDeriveFromKey(subkeyLen, subkeyId, context, key) {
  const len = expectU32(subkeyLen);
  if (typeof subkeyId !== 'number' || !Number.isInteger(subkeyId)) {
    throw new Error('TypeError: expected integer');
  }
  if (typeof context !== 'string') throw new Error('TypeError: expected string');
  const ctxBytes = new TextEncoder().encode(context);
  if (ctxBytes.length !== KDF_CONTEXT_BYTES) throw new Error('context must be exactly 8 bytes');
  const k = expectU8(key, 'key');
  if (k.length !== KDF_KEY_BYTES) throw new Error('Invalid key length');
  if (len < KDF_BYTES_MIN || len > KDF_BYTES_MAX) throw new Error('Invalid subkeyLen');
  const out = sodium.crypto_kdf_derive_from_key(len, subkeyId, context, k);
  return new Uint8Array(out);
}

// ---------------- secretbox ----------------

function secretboxEasy(message, nonce, key) {
  const m = expectU8(message, 'message');
  const n = expectU8(nonce, 'nonce');
  const k = expectU8(key, 'key');
  if (n.length !== NONCE_BYTES || k.length !== KEY_BYTES) {
    throw new Error('Invalid nonce or key length');
  }
  return new Uint8Array(sodium.crypto_secretbox_easy(m, n, k));
}

function secretboxOpenEasy(cipher, nonce, key) {
  const c = expectU8(cipher, 'cipher');
  const n = expectU8(nonce, 'nonce');
  const k = expectU8(key, 'key');
  if (n.length !== NONCE_BYTES || k.length !== KEY_BYTES) {
    throw new Error('Invalid nonce or key length');
  }
  if (c.length < sodium.crypto_secretbox_MACBYTES) throw new Error('Ciphertext too short');
  try {
    return new Uint8Array(sodium.crypto_secretbox_open_easy(c, n, k));
  } catch (e) {
    throw new Error('Decryption failed: ciphertext verification failed');
  }
}

// ---------------- box seal ----------------

function boxKeyPair() {
  const kp = sodium.crypto_box_keypair();
  // entecrypto.cpp names the properties "publicKey" / "secretKey".
  return {
    publicKey: new Uint8Array(kp.publicKey),
    secretKey: new Uint8Array(kp.privateKey),
  };
}

function boxSeal(message, publicKey) {
  const m = expectU8(message, 'message');
  const pk = expectU8(publicKey, 'publicKey');
  if (pk.length !== BOX_PUBLICKEY_BYTES) throw new Error('Invalid public key length');
  return new Uint8Array(sodium.crypto_box_seal(m, pk));
}

function boxSealOpen(cipher, publicKey, secretKey) {
  const c = expectU8(cipher, 'cipher');
  const pk = expectU8(publicKey, 'publicKey');
  const sk = expectU8(secretKey, 'secretKey');
  if (pk.length !== BOX_PUBLICKEY_BYTES || sk.length !== BOX_SECRETKEY_BYTES) {
    throw new Error('Invalid key length');
  }
  if (c.length < BOX_SEAL_BYTES) throw new Error('Ciphertext too short');
  try {
    return new Uint8Array(sodium.crypto_box_seal_open(c, pk, sk));
  } catch (e) {
    throw new Error('Decryption failed: ciphertext verification failed');
  }
}

// ---------------- secretstream (single message) ----------------

function secretstreamEncrypt(key, message) {
  const k = expectU8(key, 'key');
  const m = expectU8(message, 'message');
  if (k.length !== KEY_BYTES) throw new Error('Invalid key length');
  if (m.length > 2147483648) throw new Error('Message too large');
  const { state, header } = sodium.crypto_secretstream_xchacha20poly1305_init_push(k);
  const ct = sodium.crypto_secretstream_xchacha20poly1305_push(
    state, m, null, sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL);
  return {
    header: new Uint8Array(header),
    ciphertext: new Uint8Array(ct),
  };
}

function secretstreamDecrypt(key, header, ciphertext) {
  const k = expectU8(key, 'key');
  const h = expectU8(header, 'header');
  const c = expectU8(ciphertext, 'ciphertext');
  if (k.length !== KEY_BYTES) throw new Error('Invalid key length');
  if (h.length !== STREAM_HEADER_BYTES) throw new Error('Invalid header length');
  if (c.length < STREAM_A_BYTES) throw new Error('Ciphertext too short');
  try {
    const state = sodium.crypto_secretstream_xchacha20poly1305_init_pull(h, k);
    const r = sodium.crypto_secretstream_xchacha20poly1305_pull(state, c, null);
    if (r === false || r === null) throw new Error('pull failed');
    return new Uint8Array(r.message);
  } catch (e) {
    throw new Error('Decryption failed: ciphertext verification failed');
  }
}

export default {
  randomBytes,
  generateKey,
  getSaltToDeriveKey,
  cryptoPwHash,
  cryptoKdfDeriveFromKey,
  secretboxEasy,
  secretboxOpenEasy,
  boxKeyPair,
  boxSeal,
  boxSealOpen,
  secretstreamEncrypt,
  secretstreamDecrypt,
};

export const _sodiumVersion = sodium.SODIUM_VERSION_STRING ?? sodium.sodium_version_string?.() ?? 'unknown';
