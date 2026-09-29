/**
 * Typed wrapper around the minimal libsodium NAPI bridge (`libentecrypto.so`).
 * Mirrors the crypto primitives used by upstream `ente_crypto_dart`
 * (@981a9e0f4a227023991af3332ef0e6ab6d14a1c2):
 *  - cryptoPwHash: Argon2id v1.3, 32-byte output
 *  - cryptoKdfDeriveFromKey: blake2b kdf (context "loginctx", subkeyId 1)
 *  - secretboxEasy/OpenEasy: XSalsa20-Poly1305 (24-byte nonce)
 *  - boxSeal/Open: X25519 sealed box
 *  - secretstreamEncrypt/Decrypt: XChaCha20-Poly1305 secretstream, single
 *    FINAL message (header 24B, cipher = msg + 17B)
 *  - generateKey (32B), getSaltToDeriveKey (16B), randomBytes
 *
 * Never logs arguments or results.
 */
import entecrypto from 'libentecrypto.so';

export class NativeCryptoError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class CryptoBridge {
  /** 32-byte random key. */
  static generateKey(): Uint8Array {
    return entecrypto.generateKey() as Uint8Array;
  }

  /** 16-byte random salt for key derivation. */
  static getSaltToDeriveKey(): Uint8Array {
    return entecrypto.getSaltToDeriveKey() as Uint8Array;
  }

  static randomBytes(len: number): Uint8Array {
    return entecrypto.randomBytes(len) as Uint8Array;
  }

  /** Argon2id v1.3; 32-byte output. Throws CryptoBridgeError on failure (e.g. OOM). */
  static cryptoPwHash(password: Uint8Array, salt: Uint8Array, opsLimit: number,
    memLimit: number): Uint8Array {
    try {
      return entecrypto.cryptoPwHash(password, salt, opsLimit, memLimit) as Uint8Array;
    } catch (e) {
      throw new NativeCryptoError('KeyDerivationError: cryptoPwHash failed');
    }
  }

  /** blake2b-based KDF subkey derivation. */
  static cryptoKdfDeriveFromKey(subkeyLen: number, subkeyId: number, context: string,
    key: Uint8Array): Uint8Array {
    return entecrypto.cryptoKdfDeriveFromKey(subkeyLen, subkeyId, context, key) as Uint8Array;
  }

  static secretboxEasy(message: Uint8Array, nonce: Uint8Array, key: Uint8Array): Uint8Array {
    return entecrypto.secretboxEasy(message, nonce, key) as Uint8Array;
  }

  static secretboxOpenEasy(cipher: Uint8Array, nonce: Uint8Array, key: Uint8Array): Uint8Array {
    return entecrypto.secretboxOpenEasy(cipher, nonce, key) as Uint8Array;
  }

  static boxKeyPair(): [Uint8Array, Uint8Array] {
    const obj: object = entecrypto.boxKeyPair() as object;
    const map: Record<string, Object> = obj as Record<string, Object>;
    return [map['publicKey'] as Uint8Array, map['secretKey'] as Uint8Array];
  }

  static boxSeal(message: Uint8Array, publicKey: Uint8Array): Uint8Array {
    return entecrypto.boxSeal(message, publicKey) as Uint8Array;
  }

  static boxSealOpen(cipher: Uint8Array, publicKey: Uint8Array, secretKey: Uint8Array): Uint8Array {
    return entecrypto.boxSealOpen(cipher, publicKey, secretKey) as Uint8Array;
  }

  /** Secretstream single-message encryption; returns [header(24B), ciphertext]. */
  static secretstreamEncrypt(key: Uint8Array, message: Uint8Array): [Uint8Array, Uint8Array] {
    const obj: object = entecrypto.secretstreamEncrypt(key, message) as object;
    const map: Record<string, Object> = obj as Record<string, Object>;
    return [map['header'] as Uint8Array, map['ciphertext'] as Uint8Array];
  }

  static secretstreamDecrypt(key: Uint8Array, header: Uint8Array,
    ciphertext: Uint8Array): Uint8Array {
    return entecrypto.secretstreamDecrypt(key, header, ciphertext) as Uint8Array;
  }
}

/** Mirrors ente_crypto_api CryptoUtil static facade. */
export class EncryptionResult {
  encryptedData: Uint8Array | undefined;
  key: Uint8Array | undefined;
  header: Uint8Array | undefined;
  nonce: Uint8Array | undefined;

  constructor() {
  }
}

export class DerivedKeyResult {
  key: Uint8Array;
  memLimit: number;
  opsLimit: number;

  constructor(key: Uint8Array, memLimit: number, opsLimit: number) {
    this.key = key;
    this.memLimit = memLimit;
    this.opsLimit = opsLimit;
  }
}

export class KeyDerivationError extends Error {
  constructor() {
    super('KeyDerivationError');
  }
}

export class LoginKeyDerivationError extends Error {
  constructor() {
    super('LoginKeyDerivationError');
  }
}