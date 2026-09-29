/**
 * Configuration — account/session state holder mirroring upstream
 * `mobile/apps/auth/lib/core/configuration.dart` + the relevant parts of
 * `packages/configuration` BaseConfiguration.
 *
 * Stored keys (upstream-exact):
 *   prefs: email, key_attributes, token, encrypted_token, user_id, endpoint,
 *          has_opted_for_offline_mode, lastEntitySyncTime (in service)
 *   secure storage: key, secret_key, auth_secret_key, offline_auth_secret_key,
 *          autoBackupPassword
 */
import { Preferences } from '../storage/Preferences';
import { SecureStore } from '../storage/SecureStore';
import { CryptoUtil } from '../crypto/CryptoUtil';
import { HttpClient, DEFAULT_ENDPOINT } from '../network/HttpClient';
import { EventBus, Events } from '../events/EventBus';
import { LocalAuthEntity } from '../models/AuthenticatorEntities';
import { AuthenticatorDB } from '../storage/AuthenticatorDB';
import { OfflineAuthenticatorDB } from '../storage/OfflineAuthenticatorDB';
import { TimeOffset } from '../otp/TotpUtil';
import { KeyAttributes, KeyGenResult } from '../models/KeyAttributes';
import { Bip39 } from './Bip39';
import { toError } from '../utils/Errors';

/**
 * Upstream `kLegacyProductionEndpoint` (packages/configuration/lib/constants.dart:2).
 * Still migrated on read, exactly like upstream.
 */
const LEGACY_ENDPOINT: string = 'https://api.ente.io';

/**
 * PERSISTENCE CONTRACT (applies to every setter below)
 * ---------------------------------------------------
 * 1. Every setter that persists is `async` and AWAITS the underlying
 *    `Preferences`/`SecureStore` call. Nothing is fire-and-forget, and nothing
 *    is hidden behind `void` or `.catch(() => {})`.
 * 2. Order is PERSIST FIRST, THEN UPDATE THE CACHE. If the write fails the
 *    cached value is left untouched and the error propagates, so a durability
 *    failure becomes an operation failure instead of a silent success.
 *
 * Why the ordering is load-bearing: HarmonyOS `preferences.put()` only writes to
 * the IN-MEMORY instance; `flush()` is what stores it in the persistence file
 * (MCP js-apis-data-preferences; @ohos.data.preferences.d.ts:797-821 and
 * :946-968). `storage/Preferences.ets` performs both, so awaiting the setter is
 * what makes the write durable. Cache-before-persist would additionally make
 * "cache says signed in, disk says signed out" reachable, which is a
 * security-relevant divergence.
 *
 * This is a DELIBERATE deviation from upstream, whose `setToken` assigns
 * `_cachedToken` before awaiting (`base_configuration.dart:308-312`). Upstream's
 * ordering can leave its memo ahead of disk; this port's cannot. The difference
 * is unobservable when the write succeeds.
 */
export class PendingOnlineDataError extends Error {
  constructor() { super('还有未同步的验证码。请先恢复网络并完成同步，或导出加密备份；数据已保留，尚未退出登录。'); }
}

export class Configuration {
  private static instanceValue: Configuration | undefined = undefined;

  static get instance(): Configuration {
    if (Configuration.instanceValue === undefined) {
      Configuration.instanceValue = new Configuration();
    }
    return Configuration.instanceValue;
  }

  private constructor() {
  }

  private cachedEmail: string | undefined = undefined;
  private cachedToken: string | undefined = undefined;
  private cachedEncryptedToken: string | undefined = undefined;
  private cachedKeyAttributes: KeyAttributes | undefined = undefined;
  private cachedKey: Uint8Array | undefined = undefined;
  private cachedSecretKey: Uint8Array | undefined = undefined;
  private cachedAuthSecretKey: string | undefined = undefined;
  private cachedOfflineSecretKey: string | undefined = undefined;
  private cachedUserId: number | undefined = undefined;
  private cachedEndpoint: string | undefined = undefined;
  private accountRevision: number = 0;
  private closing: boolean = false;
  private credentialWrites: number = 0;
  private sessionExpired: boolean = false;
  private installing: boolean = false;

  assertRevision(revision: number): void {
    if (revision !== this.accountRevision || this.closing) { throw new Error('Account session changed'); }
  }

  isSessionExpired(): boolean { return this.sessionExpired || this.installing; }
  hasLocalAccount(): boolean { return this.cachedKey !== undefined; }
  isAccountWorkAllowed(): boolean { return !this.closing && this.credentialWrites === 0 && !this.sessionExpired && !this.installing; }

  assertAccountWork(revision: number): void {
    if (revision !== this.accountRevision || !this.isAccountWorkAllowed()) {
      throw new Error('Account session changed or is unavailable');
    }
  }

  /** Closes admission synchronously, before any storage/network await. */
  beginLogout(): number {
    if (this.closing) { throw new Error('Account transition already in progress'); }
    this.closing = true;
    return this.accountRevision;
  }

  async prepareLogout(revision: number): Promise<number> {
    let lease = revision;
    await this.withAccountStorage(revision, async () => {
      if (!this.closing) { throw new Error('Logout admission is not closed'); }
      await this.assertNoPendingOnlineData();
      // Only a permitted logout invalidates outstanding work. A refused logout
      // must still accept the acknowledgement of an already issued upload.
      lease = ++this.accountRevision;
    });
    return lease;
  }

  finishLogoutTransition(revision: number): void {
    if (revision === this.accountRevision) { this.closing = false; }
  }

  async assertNoPendingOnlineData(): Promise<void> {
    const rows = await AuthenticatorDB.getAll();
    if (rows.some((row: LocalAuthEntity) => row.shouldSync || row.id === undefined)) {
      throw new PendingOnlineDataError();
    }
  }

  async expireSession(revision: number): Promise<void> {
    if (revision !== this.accountRevision || this.closing || this.sessionExpired) { return; }
    this.sessionExpired = true;
    const expiredRevision = ++this.accountRevision;
    // Keep ciphertext AND keys, including unsynced rows, for export/re-login.
    try {
      await this.withAccountStorage(expiredRevision, async () => {
        await Preferences.setBool('session_expired', true);
      });
    } finally {
      if (expiredRevision === this.accountRevision) { EventBus.fire(Events.TRIGGER_LOGOUT, null); }
    }
  }

  async installLoginResponse(userId: number, encryptedToken: string | undefined,
    attributes: KeyAttributes | undefined, token: string | undefined): Promise<void> {
    if (this.closing) { throw new Error('Account transition already in progress'); }
    if (this.hasLocalAccount() && this.cachedUserId !== userId) {
      throw new Error('请重新登录原账户，或先安全退出原账户。现有数据已保留。');
    }
    if (encryptedToken !== undefined && attributes === undefined) {
      throw new Error('Login response has an encryptedToken but no keyAttributes');
    }
    this.installing = true;
    const revision = ++this.accountRevision;
    await this.withAccountStorage(revision, async () => {
      await Preferences.setBool('account_installing', true);
      await Preferences.setInt('user_id', userId);
      if (encryptedToken !== undefined) {
        await Preferences.setString('encrypted_token', encryptedToken);
        await Preferences.setString('key_attributes', (attributes as KeyAttributes).toJson());
        this.cachedEncryptedToken = encryptedToken;
        this.cachedKeyAttributes = attributes;
      } else {
        await Preferences.remove('encrypted_token');
        if (token === undefined) { await Preferences.remove('token'); }
        else { await Preferences.setString('token', token); }
        this.cachedEncryptedToken = undefined;
        this.cachedToken = token;
      }
      this.cachedUserId = userId;
    });
  }

  /** A single storage lease installs all decrypted login material. Admission
   * opens only after durable keys, token and completion markers are written. */
  async installAccountKeys(revision: number, masterKey: Uint8Array, secretKey: Uint8Array,
    token: string | undefined, attributes?: KeyAttributes): Promise<void> {
    await this.withAccountStorage(revision, async () => {
      if (this.closing || token === undefined) { throw new Error('Login is incomplete'); }
      await SecureStore.set('key', CryptoUtil.bin2base64(masterKey));
      await SecureStore.set('secret_key', CryptoUtil.bin2base64(secretKey));
      await Preferences.setString('token', token);
      if (attributes !== undefined) { await Preferences.setString('key_attributes', attributes.toJson()); }
      await Preferences.setBool('session_expired', false);
      await Preferences.setBool('account_installing', false);
      this.cachedKey = masterKey;
      this.cachedSecretKey = secretKey;
      this.cachedToken = token;
      if (attributes !== undefined) { this.cachedKeyAttributes = attributes; }
      this.sessionExpired = false;
      this.installing = false;
    });
  }

  /** Serialize credential writes with cleanup; no setter can enter during logout. */
  private async writeAccount(operation: () => Promise<void>, invalidates: boolean = false): Promise<void> {
    if (this.closing) { throw new Error('Account transition already in progress'); }
    if (invalidates) { this.accountRevision++; }
    this.credentialWrites++;
    try { await this.withAccountStorage(this.accountRevision, operation); }
    finally { this.credentialWrites--; }
  }
  private accountStorageTail: Promise<void> = Promise.resolve();

  /** Identity epoch for network continuations and serialized store commits. */
  getAccountRevision(): number {
    return this.accountRevision;
  }

  /** Serialize short account-store commits with logout, never network requests.
   * A response from an older account cannot write after logout clears its data.
   */
  async withAccountStorage(revision: number, operation: () => Promise<void>): Promise<void> {
    const previous = this.accountStorageTail;
    let release: () => void = () => {};
    this.accountStorageTail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try {
      if (revision !== this.accountRevision) {
        throw new Error('Account changed before storage commit');
      }
      await operation();
    } finally {
      release();
    }
  }

  async init(): Promise<void> {
    this.accountRevision++;
    this.closing = false;
    this.sessionExpired = await Preferences.getBool('session_expired');
    this.installing = await Preferences.getBool('account_installing');
    this.cachedEmail = await Preferences.getStringOr('email', '');
    if (this.cachedEmail === '') {
      this.cachedEmail = undefined;
    }
    const token = await Preferences.getStringOr('token', '');
    this.cachedToken = token === '' ? undefined : token;
    const encToken = await Preferences.getStringOr('encrypted_token', '');
    this.cachedEncryptedToken = encToken === '' ? undefined : encToken;
    const kaJson = await Preferences.getStringOr('key_attributes', '');
    if (kaJson !== '') {
      try {
        this.cachedKeyAttributes = KeyAttributes.fromJson(kaJson);
      } catch (e) {
        this.cachedKeyAttributes = undefined;
      }
    } else {
      // init() is a full re-read of persisted state, so an absent preference
      // must CLEAR the cache rather than leave a stale value behind. Without
      // this, a re-init against an empty store (fresh install, post-logout,
      // restart simulation) kept reporting the previous account's attributes.
      this.cachedKeyAttributes = undefined;
    }
    this.cachedUserId = await Preferences.getInt('user_id');
    const endpoint = await Preferences.getStringOr('endpoint', DEFAULT_ENDPOINT);
    this.cachedEndpoint = endpoint === '' ? DEFAULT_ENDPOINT : endpoint;
    // The legacy-endpoint migration is applied by getHttpEndpoint() on every
    // read, mirroring upstream base_configuration.dart:282-288 — so it is not
    // duplicated here.
    // Keys come from secure storage.
    const keyB64 = await SecureStore.get('key');
    this.cachedKey = keyB64 === undefined ? undefined : CryptoUtil.base642bin(keyB64);
    const skB64 = await SecureStore.get('secret_key');
    this.cachedSecretKey = skB64 === undefined ? undefined : CryptoUtil.base642bin(skB64);
    this.cachedAuthSecretKey = await SecureStore.get('auth_secret_key');
    this.cachedOfflineSecretKey = await SecureStore.get('offline_auth_secret_key');
    HttpClient.setTokenProvider(() => this.getToken());
    HttpClient.setEndpointProvider(() => this.getHttpEndpoint());
  }

  getEmail(): string | undefined {
    return this.cachedEmail;
  }

  async setEmail(email: string): Promise<void> {
    if (this.hasLocalAccount() && this.cachedEmail !== email) { throw new Error('请使用原账户重新登录'); }
    await this.writeAccount(async () => {
      await Preferences.setString('email', email);
      this.cachedEmail = email;
    }, true);
  }

  getToken(): string | undefined {
    return this.cachedToken;
  }

  async setToken(token: string | undefined): Promise<void> {
    await this.writeAccount(async () => {
      if (token === undefined) {
        await Preferences.remove('token');
      } else {
        await Preferences.setString('token', token);
      }
      this.cachedToken = token;
    }, true);
  }

  getUserId(): number | undefined {
    return this.cachedUserId;
  }

  async setUserId(id: number | undefined): Promise<void> {
    await this.writeAccount(async () => {
      if (id !== undefined) {
        await Preferences.setInt('user_id', id);
      } else {
        await Preferences.remove('user_id');
      }
      this.cachedUserId = id;
    }, true);
  }

  getHttpEndpoint(): string {
    const saved: string = this.cachedEndpoint === undefined ? DEFAULT_ENDPOINT : this.cachedEndpoint;
    // Upstream applies this migration on every read, not only at init
    // (base_configuration.dart:282-288).
    return saved === LEGACY_ENDPOINT ? DEFAULT_ENDPOINT : saved;
  }

  /**
   * Upstream `BaseConfiguration.isEnteProduction()`
   * (base_configuration.dart:290-292):
   *   `return getHttpEndpoint() == kDefaultProductionEndpoint;`
   *
   * Used by logout to decide whether a server-side failure may still be treated
   * as a local logout. The legacy endpoint counts as production because
   * getHttpEndpoint() has already migrated it.
   */
  isEnteProduction(): boolean {
    return this.getHttpEndpoint() === DEFAULT_ENDPOINT;
  }

  async setEndpoint(endpoint: string): Promise<void> {
    if (this.hasLocalAccount() && this.getHttpEndpoint() !== endpoint) { throw new Error('请先安全退出当前账户'); }
    await this.writeAccount(async () => {
      await Preferences.setString('endpoint', endpoint);
      this.cachedEndpoint = endpoint;
    }, true);
  }

  isLoggedIn(): boolean {
    return this.getToken() !== undefined;
  }

  getEncryptedToken(): string | undefined {
    return this.cachedEncryptedToken;
  }

  async setEncryptedToken(token: string | undefined): Promise<void> {
    await this.writeAccount(async () => {
      if (token === undefined) {
        await Preferences.remove('encrypted_token');
      } else {
        await Preferences.setString('encrypted_token', token);
      }
      this.cachedEncryptedToken = token;
    }, true);
  }

  getKeyAttributes(): KeyAttributes | undefined {
    return this.cachedKeyAttributes;
  }

  async setKeyAttributes(attrs: KeyAttributes | undefined): Promise<void> {
    await this.writeAccount(async () => {
      if (attrs === undefined) {
        await Preferences.remove('key_attributes');
      } else {
        await Preferences.setString('key_attributes', attrs.toJson());
      }
      this.cachedKeyAttributes = attrs;
    }, false);
  }

  /**
   * NOTE — there is deliberately no `volatilePassword` here.
   *
   * Upstream keeps the plaintext password in `BaseConfiguration._volatilePassword`
   * so a passkey/2FA continuation can resume without re-prompting
   * (`user_service.dart:781`, read back at `password_entry_page.dart:65` and
   * `password_reentry_page.dart:41`). This port never read it: it was written on
   * the signup path and never read or reset anywhere, so it retained the user's
   * plaintext password in a process-lifetime singleton for no benefit (finding O).
   *
   * The port instead asks for the password again after 2FA. That is a deliberate,
   * safer deviation and is recorded in PORTING_STATUS.md. Do not "restore parity"
   * by re-adding it without also porting the passkey resume path that justifies it.
   */

  /** Token + master key, with account work currently admitted. */
  hasConfiguredAccount(): boolean {
    return this.isAccountWorkAllowed() && this.getToken() !== undefined && this.getKey() !== undefined;
  }

  getKey(): Uint8Array | undefined {
    return this.cachedKey;
  }

  async setKey(key: Uint8Array | undefined): Promise<void> {
    await this.writeAccount(async () => {
      if (key === undefined) {
        await SecureStore.delete('key');
      } else {
        await SecureStore.set('key', CryptoUtil.bin2base64(key));
      }
      this.cachedKey = key;
    }, true);
  }

  getSecretKey(): Uint8Array | undefined {
    return this.cachedSecretKey;
  }

  async setSecretKey(key: Uint8Array | undefined): Promise<void> {
    await this.writeAccount(async () => {
      if (key === undefined) {
        await SecureStore.delete('secret_key');
      } else {
        await SecureStore.set('secret_key', CryptoUtil.bin2base64(key));
      }
      this.cachedSecretKey = key;
    }, false);
  }

  getAuthSecretKey(): Uint8Array | undefined {
    return this.cachedAuthSecretKey === undefined ? undefined : CryptoUtil.base642bin(this.cachedAuthSecretKey);
  }

  async setAuthSecretKey(b64: string | undefined): Promise<void> {
    if (b64 === undefined) {
      await SecureStore.delete('auth_secret_key');
    } else {
      await SecureStore.set('auth_secret_key', b64);
    }
    this.cachedAuthSecretKey = b64;
  }

  getOfflineSecretKey(): Uint8Array | undefined {
    return this.cachedOfflineSecretKey === undefined ? undefined : CryptoUtil.base642bin(this.cachedOfflineSecretKey);
  }

  async setOfflineSecretKey(b64: string | undefined): Promise<void> {
    if (b64 === undefined) {
      await SecureStore.delete('offline_auth_secret_key');
    } else {
      await SecureStore.set('offline_auth_secret_key', b64);
    }
    this.cachedOfflineSecretKey = b64;
  }

  async hasOptedForOfflineMode(): Promise<boolean> {
    return Preferences.getBool('has_opted_for_offline_mode');
  }

  async optForOfflineMode(): Promise<void> {
    if (await SecureStore.contains('offline_auth_secret_key')) {
      this.cachedOfflineSecretKey = await SecureStore.get('offline_auth_secret_key');
    } else {
      // A surviving encrypted database is not a fresh offline account. Never
      // generate a replacement key over it, including after a lost wrapped blob.
      if ((await OfflineAuthenticatorDB.getAll()).length > 0) {
        throw new Error('Existing offline data cannot be opened');
      }
      const key: Uint8Array = CryptoUtil.generateKey();
      await this.setOfflineSecretKey(CryptoUtil.bin2base64(key));
    }
    await Preferences.setBool('has_opted_for_offline_mode', true);
  }

  async getBackupPassword(): Promise<string | undefined> {
    return SecureStore.get('autoBackupPassword');
  }

  async setBackupPassword(password: string): Promise<void> {
    await SecureStore.set('autoBackupPassword', password);
  }

  async clearBackupPassword(): Promise<void> {
    await SecureStore.delete('autoBackupPassword');
  }

  /**
   * Signup key generation — byte-for-byte mirror of upstream
   * BaseConfiguration.generateKey (packages/configuration).
   */
  async generateKey(password: string): Promise<KeyGenResult> {
    const masterKey: Uint8Array = CryptoUtil.generateKey();
    const recoveryKey: Uint8Array = CryptoUtil.generateKey();
    const encryptedMasterKey = CryptoUtil.encryptSync(masterKey, recoveryKey);
    const encryptedRecoveryKey = CryptoUtil.encryptSync(recoveryKey, masterKey);
    const kekSalt: Uint8Array = CryptoUtil.getSaltToDeriveKey();
    const derivedKeyResult = await CryptoUtil.deriveSensitiveKey(CryptoUtil.strToBin(password), kekSalt);
    const kek: Uint8Array = derivedKeyResult.key;
    const loginKey: Uint8Array = await CryptoUtil.deriveLoginKey(kek);
    const encryptedKeyData = CryptoUtil.encryptSync(masterKey, kek);
    const keyPair: [Uint8Array, Uint8Array] = CryptoUtil.generateKeyPair();
    const encryptedSecretKeyData = CryptoUtil.encryptSync(keyPair[1], masterKey);
    const attributes = new KeyAttributes(
      CryptoUtil.bin2base64(kekSalt),
      CryptoUtil.bin2base64(encryptedKeyData.encryptedData as Uint8Array),
      CryptoUtil.bin2base64(encryptedKeyData.nonce as Uint8Array),
      CryptoUtil.bin2base64(keyPair[0]),
      CryptoUtil.bin2base64(encryptedSecretKeyData.encryptedData as Uint8Array),
      CryptoUtil.bin2base64(encryptedSecretKeyData.nonce as Uint8Array),
      derivedKeyResult.memLimit,
      derivedKeyResult.opsLimit,
      CryptoUtil.bin2base64(encryptedMasterKey.encryptedData as Uint8Array),
      CryptoUtil.bin2base64(encryptedMasterKey.nonce as Uint8Array),
      CryptoUtil.bin2base64(encryptedRecoveryKey.encryptedData as Uint8Array),
      CryptoUtil.bin2base64(encryptedRecoveryKey.nonce as Uint8Array),
    );
    return new KeyGenResult(
      attributes,
      CryptoUtil.bin2base64(masterKey),
      CryptoUtil.bin2hex(recoveryKey),
      CryptoUtil.bin2base64(keyPair[1]),
      loginKey,
    );
  }

  /**
   * Login decryption: derive KEK from the password + key attributes, decrypt
   * the master key and secret key, unseal the session token. Returns the KEK.
   */
  async decryptSecretsAndGetKeyEncKey(password: string,
    attributes: KeyAttributes): Promise<Uint8Array> {
    const revision = this.accountRevision;
    const kek: Uint8Array = await CryptoUtil.deriveKey(
      CryptoUtil.strToBin(password), CryptoUtil.base642bin(attributes.kekSalt),
      attributes.memLimit, attributes.opsLimit);
    const masterKey: Uint8Array = CryptoUtil.decryptSync(
      CryptoUtil.base642bin(attributes.encryptedKey), kek,
      CryptoUtil.base642bin(attributes.keyDecryptionNonce));

    const secretKey: Uint8Array = CryptoUtil.decryptSync(
      CryptoUtil.base642bin(attributes.encryptedSecretKey), masterKey,
      CryptoUtil.base642bin(attributes.secretKeyDecryptionNonce));
    let sessionToken = this.getToken();
    const encryptedToken: string | undefined = this.getEncryptedToken();
    if (encryptedToken !== undefined) {
      const token: Uint8Array = CryptoUtil.openSealSync(
        CryptoUtil.base642bin(encryptedToken), CryptoUtil.base642bin(attributes.publicKey), secretKey);
      sessionToken = CryptoUtil.bin2base64(token, true);
    }
    await this.installAccountKeys(revision, masterKey, secretKey, sessionToken);
    return kek;
  }

  /** New password attributes for an existing account (password change). */
  async getAttributesForNewPassword(password: string): Promise<[KeyAttributes, Uint8Array]> {
    const existing = this.getKeyAttributes();
    if (existing === undefined) {
      throw new Error('Key attributes missing');
    }
    const masterKey: Uint8Array = this.getKey() as Uint8Array;
    const kekSalt: Uint8Array = CryptoUtil.getSaltToDeriveKey();
    const derivedKeyResult = await CryptoUtil.deriveSensitiveKey(CryptoUtil.strToBin(password), kekSalt);
    const kek: Uint8Array = derivedKeyResult.key;
    const loginKey: Uint8Array = await CryptoUtil.deriveLoginKey(kek);
    const encryptedKeyData = CryptoUtil.encryptSync(masterKey, kek);
    const updated = existing.copyWith(
      CryptoUtil.bin2base64(kekSalt),
      CryptoUtil.bin2base64(encryptedKeyData.encryptedData as Uint8Array),
      CryptoUtil.bin2base64(encryptedKeyData.nonce as Uint8Array),
      undefined, undefined, undefined,
      derivedKeyResult.memLimit, derivedKeyResult.opsLimit,
      undefined, undefined, undefined, undefined);
    return [updated, loginKey];
  }

  /**
   * Account recovery with the recovery key (hex or 24-word BIP39 mnemonic) —
   * mirror of upstream BaseConfiguration.recover.
   */
  async recover(recoveryKeyInput: string): Promise<void> {
    const revision = this.accountRevision;
    const MNEMONIC_WORD_COUNT: number = 24;
    let recoveryKeyHex: string = recoveryKeyInput;
    if (recoveryKeyHex.includes(' ')) {
      const split: string[] = recoveryKeyHex.split(' ');
      if (split.length !== MNEMONIC_WORD_COUNT) {
        let extraSpaceHint: string = '';
        for (let i = 0; i < split.length; i++) {
          if (split[i].length === 0) {
            extraSpaceHint = `\n\nExtra space after word at position ${i}`;
            break;
          }
        }
        throw new Error(
          `\nRecovery code should have ${MNEMONIC_WORD_COUNT} words, ` +
          `found ${split.length} words instead.${extraSpaceHint}`);
      }
      recoveryKeyHex = await Bip39.mnemonicToEntropy(recoveryKeyHex);
    }
    const keyAttributes = this.getKeyAttributes();
    const encryptedToken = this.getEncryptedToken();
    if (keyAttributes === undefined || encryptedToken === undefined) {
      throw new Error('Key attributes not set');
    }
    let masterKey: Uint8Array;
    try {
      masterKey = CryptoUtil.decryptSync(
        CryptoUtil.base642bin(keyAttributes.masterKeyEncryptedWithRecoveryKey),
        CryptoUtil.hex2bin(recoveryKeyHex),
        CryptoUtil.base642bin(keyAttributes.masterKeyDecryptionNonce));
    } catch (e) {
      throw toError(e);
    }
    const secretKey: Uint8Array = CryptoUtil.decryptSync(
      CryptoUtil.base642bin(keyAttributes.encryptedSecretKey), masterKey,
      CryptoUtil.base642bin(keyAttributes.secretKeyDecryptionNonce));
    const token: Uint8Array = CryptoUtil.openSealSync(
      CryptoUtil.base642bin(encryptedToken), CryptoUtil.base642bin(keyAttributes.publicKey), secretKey);
    await this.installAccountKeys(revision, masterKey, secretKey, CryptoUtil.bin2base64(token, true));
  }

  /**
   * Logout storage ownership follows upstream BaseConfiguration.logout().
   * Deliberate stronger guard: pending online data prevents local cleanup.
   * clears ordinary preferences (not the reserved secstore: namespace), deletes secure-storage keys
   * [key, secret_key, auth_secret_key] (offline key persists), clears the
   * online DB (offline DB is NOT cleared), fires SignedOutEvent.
   */
  async logout(lease?: number): Promise<void> {
    let revision = lease === undefined ? this.beginLogout() : lease;
    try {
      if (lease === undefined) { revision = await this.prepareLogout(revision); }
      await this.withAccountStorage(revision, async () => {
        if (!this.closing) { throw new Error('Logout lease is no longer active'); }
        await this.assertNoPendingOnlineData();
        await Preferences.clear();
        await SecureStore.delete('key');
        await SecureStore.delete('secret_key');
        await SecureStore.delete('auth_secret_key');
        await AuthenticatorDB.clearTable();
        this.cachedEmail = undefined;
        this.cachedToken = undefined;
        this.cachedEncryptedToken = undefined;
        this.cachedKeyAttributes = undefined;
        this.cachedKey = undefined;
        this.cachedSecretKey = undefined;
        this.cachedAuthSecretKey = undefined;
        this.cachedUserId = undefined;
        this.cachedEndpoint = undefined;
        this.sessionExpired = false;
        this.installing = false;
        TimeOffset.setOffset(0);
        EventBus.fire(Events.SIGNED_OUT, null);
      });
    } finally { this.finishLogoutTransition(revision); }
  }
}
