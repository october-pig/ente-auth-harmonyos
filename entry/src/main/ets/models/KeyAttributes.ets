/**
 * KeyAttributes — mirror of upstream `packages/base/lib/models/key_attributes.dart`.
 * Exact JSON key names.
 */
export class KeyAttributes {
  kekSalt: string;
  encryptedKey: string;
  keyDecryptionNonce: string;
  publicKey: string;
  encryptedSecretKey: string;
  secretKeyDecryptionNonce: string;
  memLimit: number;
  opsLimit: number;
  masterKeyEncryptedWithRecoveryKey: string;
  masterKeyDecryptionNonce: string;
  recoveryKeyEncryptedWithMasterKey: string;
  recoveryKeyDecryptionNonce: string;

  constructor(kekSalt: string, encryptedKey: string, keyDecryptionNonce: string,
    publicKey: string, encryptedSecretKey: string, secretKeyDecryptionNonce: string,
    memLimit: number, opsLimit: number, masterKeyEncryptedWithRecoveryKey: string,
    masterKeyDecryptionNonce: string, recoveryKeyEncryptedWithMasterKey: string,
    recoveryKeyDecryptionNonce: string) {
    this.kekSalt = kekSalt;
    this.encryptedKey = encryptedKey;
    this.keyDecryptionNonce = keyDecryptionNonce;
    this.publicKey = publicKey;
    this.encryptedSecretKey = encryptedSecretKey;
    this.secretKeyDecryptionNonce = secretKeyDecryptionNonce;
    this.memLimit = memLimit;
    this.opsLimit = opsLimit;
    this.masterKeyEncryptedWithRecoveryKey = masterKeyEncryptedWithRecoveryKey;
    this.masterKeyDecryptionNonce = masterKeyDecryptionNonce;
    this.recoveryKeyEncryptedWithMasterKey = recoveryKeyEncryptedWithMasterKey;
    this.recoveryKeyDecryptionNonce = recoveryKeyDecryptionNonce;
  }

  toMap(): object {
    const m: Record<string, Object> = {};
    m['kekSalt'] = this.kekSalt;
    m['encryptedKey'] = this.encryptedKey;
    m['keyDecryptionNonce'] = this.keyDecryptionNonce;
    m['publicKey'] = this.publicKey;
    m['encryptedSecretKey'] = this.encryptedSecretKey;
    m['secretKeyDecryptionNonce'] = this.secretKeyDecryptionNonce;
    m['memLimit'] = this.memLimit;
    m['opsLimit'] = this.opsLimit;
    m['masterKeyEncryptedWithRecoveryKey'] = this.masterKeyEncryptedWithRecoveryKey;
    m['masterKeyDecryptionNonce'] = this.masterKeyDecryptionNonce;
    m['recoveryKeyEncryptedWithMasterKey'] = this.recoveryKeyEncryptedWithMasterKey;
    m['recoveryKeyDecryptionNonce'] = this.recoveryKeyDecryptionNonce;
    return m;
  }

  static fromMap(map: object): KeyAttributes {
    const m: Record<string, Object> = map as Record<string, Object>;
    const gs = (k: string): string => (m[k] === undefined || m[k] === null ? '' : (m[k] as string));
    const gn = (k: string): number => (m[k] === undefined ? 0 : (m[k] as number));
    return new KeyAttributes(
      gs('kekSalt'), gs('encryptedKey'), gs('keyDecryptionNonce'), gs('publicKey'),
      gs('encryptedSecretKey'), gs('secretKeyDecryptionNonce'), gn('memLimit'), gn('opsLimit'),
      gs('masterKeyEncryptedWithRecoveryKey'), gs('masterKeyDecryptionNonce'),
      gs('recoveryKeyEncryptedWithMasterKey'), gs('recoveryKeyDecryptionNonce'));
  }

  toJson(): string {
    return JSON.stringify(this.toMap());
  }

  static fromJson(source: string): KeyAttributes {
    return KeyAttributes.fromMap(JSON.parse(source) as object);
  }

  copyWith(kekSalt?: string, encryptedKey?: string, keyDecryptionNonce?: string,
    publicKey?: string, encryptedSecretKey?: string, secretKeyDecryptionNonce?: string,
    memLimit?: number, opsLimit?: number, masterKeyEncryptedWithRecoveryKey?: string,
    masterKeyDecryptionNonce?: string, recoveryKeyEncryptedWithMasterKey?: string,
    recoveryKeyDecryptionNonce?: string): KeyAttributes {
    return new KeyAttributes(
      kekSalt === undefined ? this.kekSalt : kekSalt,
      encryptedKey === undefined ? this.encryptedKey : encryptedKey,
      keyDecryptionNonce === undefined ? this.keyDecryptionNonce : keyDecryptionNonce,
      publicKey === undefined ? this.publicKey : publicKey,
      encryptedSecretKey === undefined ? this.encryptedSecretKey : encryptedSecretKey,
      secretKeyDecryptionNonce === undefined ? this.secretKeyDecryptionNonce : secretKeyDecryptionNonce,
      memLimit === undefined ? this.memLimit : memLimit,
      opsLimit === undefined ? this.opsLimit : opsLimit,
      masterKeyEncryptedWithRecoveryKey === undefined
        ? this.masterKeyEncryptedWithRecoveryKey : masterKeyEncryptedWithRecoveryKey,
      masterKeyDecryptionNonce === undefined ? this.masterKeyDecryptionNonce : masterKeyDecryptionNonce,
      recoveryKeyEncryptedWithMasterKey === undefined
        ? this.recoveryKeyEncryptedWithMasterKey : recoveryKeyEncryptedWithMasterKey,
      recoveryKeyDecryptionNonce === undefined
        ? this.recoveryKeyDecryptionNonce : recoveryKeyDecryptionNonce);
  }
}

/** SetKeysRequest — srp update payload (packages/accounts/models). */
export class SetKeysRequest {
  kekSalt: string;
  encryptedKey: string;
  keyDecryptionNonce: string;
  memLimit: number;
  opsLimit: number;

  constructor(kekSalt: string, encryptedKey: string, keyDecryptionNonce: string,
    memLimit: number, opsLimit: number) {
    this.kekSalt = kekSalt;
    this.encryptedKey = encryptedKey;
    this.keyDecryptionNonce = keyDecryptionNonce;
    this.memLimit = memLimit;
    this.opsLimit = opsLimit;
  }

  toMap(): object {
    const m: Record<string, Object> = {};
    m['kekSalt'] = this.kekSalt;
    m['encryptedKey'] = this.encryptedKey;
    m['keyDecryptionNonce'] = this.keyDecryptionNonce;
    m['memLimit'] = this.memLimit;
    m['opsLimit'] = this.opsLimit;
    return m;
  }
}

export class KeyGenResult {
  keyAttributes: KeyAttributes;
  key: string;            // b64 master key
  recoveryKey: string;    // hex
  secretKey: string;      // b64
  loginKey: Uint8Array;

  constructor(keyAttributes: KeyAttributes, key: string, recoveryKey: string,
    secretKey: string, loginKey: Uint8Array) {
    this.keyAttributes = keyAttributes;
    this.key = key;
    this.recoveryKey = recoveryKey;
    this.secretKey = secretKey;
    this.loginKey = loginKey;
  }
}