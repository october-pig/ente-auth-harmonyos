/**
 * AuthenticatorService — mirror of upstream
 * `mobile/apps/auth/lib/services/authenticator_service.dart`.
 *
 * Owns the local encrypted entities, the sync state machine (remote→local,
 * local→remote, coalesced), and the per-mode data key.
 */
import { Configuration } from '../account/Configuration';
import { AuthenticatorDB } from '../storage/AuthenticatorDB';
import { OfflineAuthenticatorDB } from '../storage/OfflineAuthenticatorDB';
import { AuthenticatorGateway } from '../gateway/AuthenticatorGateway';
import { Preferences } from '../storage/Preferences';
import { EntityResult, AuthEntity, LocalAuthEntity, AuthKey } from '../models/AuthenticatorEntities';
import { CryptoUtil } from '../crypto/CryptoUtil';
import { UnauthorizedError, AuthenticatorKeyNotFound } from '../network/HttpClient';
import { PreferenceService } from './PreferenceService';
import { EventBus, Events } from '../events/EventBus';
import { Logger } from '../utils/Logger';
import { toError } from '../utils/Errors';

export enum AccountMode {
  online = 0,
  offline = 1,
}

/** Aggregate-only read error; never carries an entity, key or underlying crypto error. */
export class UnreadableAuthenticatorDataError extends Error {
  readonly rawRowCount: number;
  readonly decryptSuccessCount: number;
  readonly decryptFailureCount: number;

  constructor(rows: number, succeeded: number, failed: number) {
    super('Stored authenticator data could not be read');
    this.rawRowCount = rows;
    this.decryptSuccessCount = succeeded;
    this.decryptFailureCount = failed;
  }
}

export class AuthenticatorService {
  private static instanceValue: AuthenticatorService | undefined = undefined;

  static get instance(): AuthenticatorService {
    if (AuthenticatorService.instanceValue === undefined) {
      AuthenticatorService.instanceValue = new AuthenticatorService();
    }
    return AuthenticatorService.instanceValue;
  }

  private constructor() {
  }

  private static readonly LAST_ENTITY_SYNC_TIME: string = 'lastEntitySyncTime';
  private onlineSyncInFlight: Promise<boolean> | undefined = undefined;
  private onlineSyncRevision: number = 0;
  private onlineSyncRerunRequested: boolean = false;
  private initialized: boolean = false;

  async init(): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    if (Configuration.instance.hasConfiguredAccount()) {
      this.onlineSync();
    }
  }

  async getAccountMode(): Promise<AccountMode> {
    const offline: boolean = await Configuration.instance.hasOptedForOfflineMode();
    const hasAccount: boolean = Configuration.instance.hasLocalAccount();
    return offline && !hasAccount ? AccountMode.offline : AccountMode.online;
  }

  /** Complete read: do not report partial/unreadable persisted data as empty. */
  async getEntities(mode: AccountMode): Promise<EntityResult[]> {
    const result: LocalAuthEntity[] = mode === AccountMode.online
      ? await AuthenticatorDB.getAll()
      : await OfflineAuthenticatorDB.getAll();
    const entities: EntityResult[] = [];
    if (result.length === 0) {
      return entities;
    }
    if (mode === AccountMode.offline && Configuration.instance.getOfflineSecretKey() === undefined) {
      throw new UnreadableAuthenticatorDataError(result.length, 0, result.length);
    }
    const key: Uint8Array = await this.getOrCreateAuthDataKey(mode);
    let failures: number = 0;
    for (let i = 0; i < result.length; i++) {
      const e = result[i];
      try {
        const decryptedValue: Uint8Array = await CryptoUtil.decryptData(
          CryptoUtil.base642bin(e.encryptedData), key, CryptoUtil.base642bin(e.header));
        const hasSynced: boolean = !(e.id === undefined || e.shouldSync);
        entities.push(new EntityResult(e.generatedID, Utf8Decode(decryptedValue), hasSynced));
      } catch (err) {
        failures++;
      }
    }
    if (failures > 0) {
      throw new UnreadableAuthenticatorDataError(result.length, entities.length, failures);
    }
    return entities;
  }

  async addEntry(plainText: string, shouldSync: boolean, accountMode: AccountMode): Promise<number> {
    const revision = Configuration.instance.getAccountRevision();
    if (accountMode === AccountMode.online) { this.assertSyncSession(revision); }
    const key: Uint8Array = await this.getOrCreateAuthDataKey(accountMode);
    const encryptedKeyData = await CryptoUtil.encryptData(CryptoUtil.strToBin(plainText), key);
    const encryptedData: string = CryptoUtil.bin2base64(encryptedKeyData.encryptedData as Uint8Array);
    const header: string = CryptoUtil.bin2base64(encryptedKeyData.header as Uint8Array);
    let insertedID: number = 0;
    if (accountMode === AccountMode.online) {
      await Configuration.instance.withAccountStorage(revision, async () => {
        this.assertSyncSession(revision);
        insertedID = await AuthenticatorDB.insert(encryptedData, header);
      });
    } else { insertedID = await OfflineAuthenticatorDB.insert(encryptedData, header); }
    if (shouldSync) {
      this.onlineSync();
    }
    return insertedID;
  }

  async updateEntry(generatedID: number, plainText: string, shouldSync: boolean,
    accountMode: AccountMode): Promise<void> {
    const revision = Configuration.instance.getAccountRevision();
    if (accountMode === AccountMode.online) { this.assertSyncSession(revision); }
    const key: Uint8Array = await this.getOrCreateAuthDataKey(accountMode);
    const encryptedKeyData = await CryptoUtil.encryptData(CryptoUtil.strToBin(plainText), key);
    const encryptedData: string = CryptoUtil.bin2base64(encryptedKeyData.encryptedData as Uint8Array);
    const header: string = CryptoUtil.bin2base64(encryptedKeyData.header as Uint8Array);
    let affectedRows: number = 0;
    if (accountMode === AccountMode.online) {
      await Configuration.instance.withAccountStorage(revision, async () => {
        this.assertSyncSession(revision);
        affectedRows = await AuthenticatorDB.updateEntry(generatedID, encryptedData, header);
      });
    } else { affectedRows = await OfflineAuthenticatorDB.updateEntry(generatedID, encryptedData, header); }
    if (affectedRows !== 1) {
      Logger.warn('updateEntry should have updated exactly one row');
    }
    if (shouldSync) {
      this.onlineSync();
    }
  }

  async deleteEntry(genID: number, accountMode: AccountMode): Promise<void> {
    const revision = Configuration.instance.getAccountRevision();
    if (accountMode === AccountMode.online) { this.assertSyncSession(revision); }
    let result: LocalAuthEntity | undefined = accountMode === AccountMode.online
      ? await AuthenticatorDB.getEntryByID(genID)
      : await OfflineAuthenticatorDB.getEntryByID(genID);
    if (result === undefined) {
      return;
    }
    if (result.id !== undefined && accountMode === AccountMode.online) {
      this.assertSyncSession(revision);
      await AuthenticatorGateway.deleteEntity(result.id);
    }
    if (accountMode === AccountMode.online) {
      await Configuration.instance.withAccountStorage(revision, async () => {
        this.assertSyncSession(revision);
        await AuthenticatorDB.deleteByIDs([genID]);
      });
    } else {
      await OfflineAuthenticatorDB.deleteByIDs([genID]);
    }
  }

  /** Coalesced online sync, mirroring upstream onlineSync/_runCoalescedOnlineSync. */
  onlineSync(): Promise<boolean> {
    if (!Configuration.instance.hasConfiguredAccount()) { return Promise.resolve(false); }
    const inFlightSync = this.onlineSyncInFlight;
    if (inFlightSync !== undefined) {
      const revision = Configuration.instance.getAccountRevision();
      if (revision !== this.onlineSyncRevision) {
        return inFlightSync.then(() => revision === Configuration.instance.getAccountRevision() ? this.onlineSync() : false);
      }
      this.onlineSyncRerunRequested = true;
      return inFlightSync;
    }
    this.onlineSyncRevision = Configuration.instance.getAccountRevision();
    const promise = this.runCoalescedOnlineSync(this.onlineSyncRevision);
    this.onlineSyncInFlight = promise;
    return promise;
  }

  private async runCoalescedOnlineSync(revision: number): Promise<boolean> {
    let lastResult: boolean = false;
    try {
      while (true) {
        this.onlineSyncRerunRequested = false;
        lastResult = await this.onlineSyncOnce(revision);
        if (!this.onlineSyncRerunRequested || revision !== Configuration.instance.getAccountRevision()) {
          break;
        }
      }
    } catch (e) {
      Logger.warn('Unexpected failure while coalescing syncs');
      lastResult = false;
    } finally {
      this.onlineSyncInFlight = undefined;
    }
    return lastResult;
  }

  private async onlineSyncOnce(revision: number): Promise<boolean> {
    try {
      if (!Configuration.instance.hasConfiguredAccount() || await this.getAccountMode() === AccountMode.offline) {
        return false;
      }
      this.assertSyncSession(revision);
      await this.remoteToLocalSync(revision);
      await this.localToRemoteSync(revision);
      this.assertSyncSession(revision);
      EventBus.fire(Events.CODES_UPDATED, null);
      return true;
    } catch (e) {
      if (Configuration.instance.getAccountRevision() !== revision) {
        return false;
      }
      if (e instanceof UnauthorizedError) {
        await Configuration.instance.expireSession(revision);
        return false;
      }
      Logger.warn('Failed to sync with remote');
      return false;
    }
  }

  private assertSyncSession(revision: number): void {
    Configuration.instance.assertAccountWork(revision);
  }

  private async remoteToLocalSync(revision: number): Promise<void> {
    // One full replay repairs gaps left behind an older strict cursor. Persist
    // the version only on a complete scan. Replays preserve pending local edits.
    const repaired = await Preferences.getBool('sync_tie_cursor_v1');
    let cursor = repaired ? await Preferences.getIntOr(AuthenticatorService.LAST_ENTITY_SYNC_TIME, 0) : 0;
    let since = Math.max(0, cursor - 1);
    let limit: number = 500;
    while (true) {
      this.assertSyncSession(revision);
      const pair = await AuthenticatorGateway.getDiff(since, limit);
      this.assertSyncSession(revision);
      const rows = pair[0];
      let maximum = cursor;
      for (const row of rows) {
        if (!Number.isSafeInteger(row.updatedAt) || row.updatedAt <= since) {
          throw new Error('Invalid sync timestamp');
        }
        maximum = Math.max(maximum, row.updatedAt);
      }
      await Configuration.instance.withAccountStorage(revision, async () => {
        await PreferenceService.computeAndStoreTimeOffset(pair[1]);
        const local = await AuthenticatorDB.getAll();
        const kept: AuthEntity[] = [];
        const deleted: string[] = [];
        for (const row of rows) {
          const old = local.find((item: LocalAuthEntity) => item.id === row.id);
          if (old !== undefined && old.shouldSync) { continue; }
          if (row.isDeleted) { deleted.push(row.id); }
          else if (old === undefined || old.encryptedData !== row.encryptedData ||
            old.header !== row.header || old.updatedAt !== row.updatedAt) { kept.push(row); }
        }
        await AuthenticatorDB.insertOrReplace(kept);
        if (deleted.length > 0) { await AuthenticatorDB.deleteByIDs(undefined, deleted); }
        // Every future read overlaps this boundary; never advance beyond it.
        if (rows.length > 0) { await Preferences.setInt(AuthenticatorService.LAST_ENTITY_SYNC_TIME, maximum); }
        if (rows.length < limit) { await Preferences.setBool('sync_tie_cursor_v1', true); }
      });
      if (rows.length < limit) { return; }
      const nextSince = Math.max(0, maximum - 1);
      if (nextSince <= since) {
        if (limit >= 5000) { throw new Error('Sync timestamp bucket exceeds server page limit'); }
        limit = Math.min(5000, limit * 2);
      } else { since = nextSince; limit = 500; }
      cursor = maximum;
    }
  }

  private async localToRemoteSync(revision: number): Promise<void> {
    const result: LocalAuthEntity[] = await AuthenticatorDB.getAll();
    this.assertSyncSession(revision);
    const pendingUpdate: LocalAuthEntity[] = [];
    for (let i = 0; i < result.length; i++) {
      if (result[i].shouldSync || result[i].id === undefined) {
        pendingUpdate.push(result[i]);
      }
    }
    for (let i = 0; i < pendingUpdate.length; i++) {
      const entity = pendingUpdate[i];
      this.assertSyncSession(revision);
      if (entity.id === undefined) {
        const authEntity: AuthEntity = await AuthenticatorGateway.createEntity(entity.encryptedData, entity.header);
        await Configuration.instance.withAccountStorage(revision, async () => {
          await this.acknowledgeUpload(entity, authEntity.id);
        });
      } else {
        await AuthenticatorGateway.updateEntity(entity.id, entity.encryptedData, entity.header);
        await Configuration.instance.withAccountStorage(revision, async () => {
          await this.acknowledgeUpload(entity, entity.id as string);
        });
      }
    }
    if (pendingUpdate.length > 0) {
      await this.remoteToLocalSync(revision);
    }
  }

  private async acknowledgeUpload(sent: LocalAuthEntity, id: string): Promise<void> {
    const current = await AuthenticatorDB.getEntryByID(sent.generatedID);
    if (current === undefined) { return; }
    const changed = current.encryptedData !== sent.encryptedData || current.header !== sent.header;
    await AuthenticatorDB.updateLocalEntity(current.copyWith(undefined, id, undefined, undefined,
      undefined, undefined, changed));
  }

  /** Data key: offline key for offline mode; auth key fetched/created online. */
  async getOrCreateAuthDataKey(mode: AccountMode): Promise<Uint8Array> {
    if (mode === AccountMode.offline) {
      const k = Configuration.instance.getOfflineSecretKey();
      if (k === undefined) {
        throw new Error('Offline secret key not available');
      }
      return k;
    }
    const cached = Configuration.instance.getAuthSecretKey();
    if (cached !== undefined) {
      return cached;
    }
    const revision = Configuration.instance.getAccountRevision();
    this.assertSyncSession(revision);
    try {
      const response: AuthKey = await AuthenticatorGateway.getKey();
      this.assertSyncSession(revision);
      const masterKey = Configuration.instance.getKey();
      if (masterKey === undefined) {
        throw new Error('Master key not available');
      }
      const authKey: Uint8Array = CryptoUtil.decryptSync(
        CryptoUtil.base642bin(response.encryptedKey), masterKey, CryptoUtil.base642bin(response.header));
      await Configuration.instance.withAccountStorage(revision, async () => {
        await Configuration.instance.setAuthSecretKey(CryptoUtil.bin2base64(authKey));
      });
      return authKey;
    } catch (e) {
      if (e instanceof AuthenticatorKeyNotFound) {
        this.assertSyncSession(revision);
        const key: Uint8Array = CryptoUtil.generateKey();
        const masterKey = Configuration.instance.getKey();
        if (masterKey === undefined) {
          throw new Error('Master key not available');
        }
        const encryptedKeyData = CryptoUtil.encryptSync(key, masterKey);
        await AuthenticatorGateway.createKey(
          CryptoUtil.bin2base64(encryptedKeyData.encryptedData as Uint8Array),
          CryptoUtil.bin2base64(encryptedKeyData.nonce as Uint8Array));
        await Configuration.instance.withAccountStorage(revision, async () => {
          await Configuration.instance.setAuthSecretKey(CryptoUtil.bin2base64(key));
        });
        return key;
      }
      throw toError(e);
    }
  }
}

function Utf8Decode(bytes: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      i++;
    } else if ((b0 & 0xE0) === 0xC0) {
      out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if ((b0 & 0xF0) === 0xE0) {
      out += String.fromCharCode(((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
      i += 3;
    } else {
      const cp: number = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) |
        ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
      const adj: number = cp - 0x10000;
      out += String.fromCharCode(0xD800 + (adj >> 10), 0xDC00 + (adj & 0x3FF));
      i += 4;
    }
  }
  return out;
}
