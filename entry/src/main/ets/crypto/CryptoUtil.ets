/**
 * CryptoUtil — ArkTS facade mirroring upstream `ente_crypto_api` CryptoUtil
 * implemented over the minimal native libsodium bridge.
 *
 * Exact upstream semantics (ente_crypto_dart @981a9e0f):
 *  - encryptData/decryptData: XChaCha20-Poly1305 secretstream single message;
 *    returns {encryptedData (b64), header (b64)}; header = 24-byte stream header.
 *  - encryptSync/decryptSync: XSalsa20-Poly1305 secretbox with 24-byte nonce;
 *    `nonce` field = the nonce (used as AuthKey header on the wire).
 *  - deriveKey: Argon2id v1.3, 32-byte out.
 *  - deriveSensitiveKey: adaptive memLimit/opsLimit loop (see below).
 *  - deriveInteractiveKey: memLimitInteractive × opsLimitInteractive.
 *  - deriveLoginKey: kdf subkey id=1 len=32 ctx "loginctx", then first 16 bytes.
 *  - generateKey: 32 random bytes; getSaltToDeriveKey: 16 random bytes.
 *  - base642bin/bin2base64: standard base64 (with padding).
 */
import { util } from '@kit.ArkTS';
import { CryptoBridge, DerivedKeyResult, EncryptionResult, KeyDerivationError, LoginKeyDerivationError } from './CryptoBridge';
import { Utf8Strict } from '../models/UriComponent';

// libsodium pwhash limits (fixed by libsodium; source of truth libsodium.h)
export const PW_MEM_LIMIT_INTERACTIVE = 67_108_864;   // 64 MiB
export const PW_OPS_LIMIT_INTERACTIVE = 2;
export const PW_MEM_LIMIT_MODERATE = 268_435_456;     // 256 MiB
export const PW_OPS_LIMIT_MODERATE = 3;
export const PW_MEM_LIMIT_SENSITIVE = 1_073_741_824;  // 1 GiB
export const PW_OPS_LIMIT_SENSITIVE = 4;
export const PW_MEM_LIMIT_MIN = 8_192;
export const PW_OPS_LIMIT_MAX = 4_294_967_295;

const LOGIN_SUB_KEY_LEN = 32;
const LOGIN_SUB_KEY_ID = 1;
const LOGIN_SUB_KEY_CONTEXT = 'loginctx';

const b64: util.Base64Helper = new util.Base64Helper();

export class CryptoUtil {
  private constructor() {
  }

  /**
   * Upstream `CryptoUtil.strToBin` is `Uint8List.fromList(str.codeUnits)`, i.e.
   * UTF-16 code units truncated to 8 bits. That is LOSSY for any non-ASCII
   * character and is only ever used upstream to hand an exported text file to
   * the platform file saver (export_widget.dart:176); the sibling code path in
   * the same function writes the same content with `writeAsStringSync`, i.e.
   * real UTF-8.
   *
   * DELIBERATE DEVIATION (documented in docs/TESTING.md, severity LOW):
   * this port returns real UTF-8 so exported files are valid text. This is
   * safe because no crypto path uses strToBin upstream — passwords go through
   * `utf8.encode` (base_configuration.dart:124,198), which is exactly what
   * `Utf8Strict.encode` produces. `utf8Encode` below is the explicit alias
   * used by the password paths so the two concerns can never be conflated.
   */
  static strToBin(str: string): Uint8Array {
    return Utf8Strict.encode(str);
  }

  /** `utf8.encode(str)` in Dart — the encoding upstream uses for passwords. */
  static utf8Encode(str: string): Uint8Array {
    return Utf8Strict.encode(str);
  }

  /**
   * Dart `base64.decode` is lenient: it accepts BOTH the standard and the
   * URL-safe alphabet and tolerates missing padding. Mirror that exactly,
   * because `getEncryptedToken()`/`getToken()` values are produced with
   * `bin2base64(..., urlSafe: true)` and fed back here.
   */
  static base642bin(b64Str: string): Uint8Array {
    const normalized: string = b64Str.replace(/-/g, '+').replace(/_/g, '/');
    const rem: number = normalized.length % 4;
    if (rem === 1) {
      throw new Error('FormatException: Invalid base64 length');
    }
    let padded: string = normalized;
    if (rem === 2) {
      padded = normalized + '==';
    } else if (rem === 3) {
      padded = normalized + '=';
    }
    return b64.decodeSync(padded);
  }

  /**
   * Dart `base64.encode` (standard, padded) or `base64UrlEncode`
   * (RFC 4648 §5 alphabet, **padding retained**) when urlSafe is true.
   *
   * NOTE: `String.replace(string, string)` replaces only the FIRST match, so
   * global regexes are required here. Upstream uses `base64UrlEncode`
   * (base_configuration.dart:231,279) whose output keeps the '=' padding and
   * is sent verbatim as the `X-Auth-Token` header value.
   */
  static bin2base64(bin: Uint8Array, urlSafe: boolean = false): string {
    const s: string = b64.encodeToStringSync(bin);
    if (urlSafe) {
      return s.replace(/\+/g, '-').replace(/\//g, '_');
    }
    return s;
  }

  static bin2hex(bin: Uint8Array): string {
    let out: string = '';
    for (let i = 0; i < bin.length; i++) {
      const h: string = bin[i].toString(16);
      out = out + (h.length === 1 ? '0' + h : h);
    }
    return out;
  }

  static hex2bin(hex: string): Uint8Array {
    const bytes: number[] = [];
    for (let i = 0; i + 1 < hex.length; i += 2) {
      bytes.push(parseInt(hex.substring(i, i + 2), 16));
    }
    return Uint8Array.from(bytes);
  }

  /** XSalsa20-Poly1305 encrypt with a fresh random 24-byte nonce. */
  static encryptSync(source: Uint8Array, key: Uint8Array): EncryptionResult {
    const nonce: Uint8Array = CryptoBridge.randomBytes(24);
    const encryptedData: Uint8Array = CryptoBridge.secretboxEasy(source, nonce, key);
    const result: EncryptionResult = new EncryptionResult();
    result.key = key;
    result.nonce = nonce;
    result.encryptedData = encryptedData;
    return result;
  }

  static decryptSync(cipher: Uint8Array, key: Uint8Array, nonce: Uint8Array): Uint8Array {
    return CryptoBridge.secretboxOpenEasy(cipher, nonce, key);
  }

  /** XChaCha20-Poly1305 secretstream encrypt; header + ciphertext. */
  static async encryptData(source: Uint8Array, key: Uint8Array): Promise<EncryptionResult> {
    const pair: [Uint8Array, Uint8Array] = CryptoBridge.secretstreamEncrypt(key, source);
    const result: EncryptionResult = new EncryptionResult();
    result.encryptedData = pair[1];
    result.header = pair[0];
    return result;
  }

  static async decryptData(source: Uint8Array, key: Uint8Array, header: Uint8Array): Promise<Uint8Array> {
    return CryptoBridge.secretstreamDecrypt(key, header, source);
  }

  static generateKey(): Uint8Array {
    return CryptoBridge.generateKey();
  }

  static getSaltToDeriveKey(): Uint8Array {
    return CryptoBridge.getSaltToDeriveKey();
  }

  static generateKeyPair(): [Uint8Array, Uint8Array] {
    return CryptoBridge.boxKeyPair();
  }

  static openSealSync(input: Uint8Array, publicKey: Uint8Array, secretKey: Uint8Array): Uint8Array {
    return CryptoBridge.boxSealOpen(input, publicKey, secretKey);
  }

  static sealSync(input: Uint8Array, publicKey: Uint8Array): Uint8Array {
    return CryptoBridge.boxSeal(input, publicKey);
  }

  /** Argon2id v1.3 with explicit params. Throws KeyDerivationError on failure. */
  static async deriveKey(password: Uint8Array, salt: Uint8Array, memLimit: number,
    opsLimit: number): Promise<Uint8Array> {
    try {
      return CryptoBridge.cryptoPwHash(password, salt, opsLimit, memLimit);
    } catch (e) {
      throw new KeyDerivationError();
    }
  }

  /**
   * Adaptive-sensitive Argon2id: starts at libsodium SENSITIVE params (or
   * MODERATE on low-spec devices), halving mem / doubling ops on failure,
   * keeping mem×ops constant; mirrors ente_crypto_dart deriveSensitiveKey.
   */
  static async deriveSensitiveKey(password: Uint8Array, salt: Uint8Array): Promise<DerivedKeyResult> {
    const desiredStrength: number = PW_MEM_LIMIT_SENSITIVE * PW_OPS_LIMIT_SENSITIVE;
    let memLimit: number = PW_MEM_LIMIT_SENSITIVE;
    let opsLimit: number = PW_OPS_LIMIT_SENSITIVE;
    if (memLimit * opsLimit !== desiredStrength) {
      throw new Error('unexpected values for memLimit and opsLimit');
    }
    while (memLimit >= PW_MEM_LIMIT_MIN && opsLimit <= PW_OPS_LIMIT_MAX) {
      try {
        const key: Uint8Array = await CryptoUtil.deriveKey(password, salt, memLimit, opsLimit);
        return new DerivedKeyResult(key, memLimit, opsLimit);
      } catch (e) {
        // fall through: halve memory, double ops
      }
      memLimit = Math.round(memLimit / 2);
      opsLimit = opsLimit * 2;
    }
    throw new Error('Cannot perform this operation on this device');
  }

  /** Argon2id interactive (shared-link password derivation; retained for parity). */
  static async deriveInteractiveKey(password: Uint8Array, salt: Uint8Array): Promise<DerivedKeyResult> {
    const memLimit: number = PW_MEM_LIMIT_INTERACTIVE;
    const opsLimit: number = PW_OPS_LIMIT_INTERACTIVE;
    const key: Uint8Array = await CryptoUtil.deriveKey(password, salt, memLimit, opsLimit);
    return new DerivedKeyResult(key, memLimit, opsLimit);
  }

  /** Login key = kdf subkey (id 1, len 32, ctx "loginctx") truncated to 16 bytes. */
  static async deriveLoginKey(key: Uint8Array): Promise<Uint8Array> {
    try {
      const derived: Uint8Array = CryptoBridge.cryptoKdfDeriveFromKey(
        LOGIN_SUB_KEY_LEN, LOGIN_SUB_KEY_ID, LOGIN_SUB_KEY_CONTEXT, key);
      return derived.subarray(0, 16);
    } catch (e) {
      throw new LoginKeyDerivationError();
    }
  }
}