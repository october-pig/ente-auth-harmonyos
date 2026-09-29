/**
 * CodeStore — mirror of upstream `store/code_store.dart`: app-level code
 * state (load/add/remove/reorder/offline-import/export).
 */
import { AuthenticatorService, AccountMode, UnreadableAuthenticatorDataError } from '../services/AuthenticatorService';
import { Code } from '../models/Code';
import { AuthEntity, EntityResult, LocalAuthEntity } from '../models/AuthenticatorEntities';
import { CodeParseError } from './CodeParseError';
import { EventBus, Events } from '../events/EventBus';
import { Configuration } from '../account/Configuration';
import { OfflineAuthenticatorDB } from '../storage/OfflineAuthenticatorDB';
import { Logger } from '../utils/Logger';
import { AuthenticatorGateway } from '../gateway/AuthenticatorGateway';
import { OfflineMigrationJournal } from '../storage/OfflineMigrationJournal';
import { CryptoUtil } from '../crypto/CryptoUtil';
import { util } from '@kit.ArkTS';

export type OfflineMigrationResult = 'complete' | 'retry' | 'uncertain' | 'unreadable' | 'cancelled';

class MigrationUnreadableError extends Error {
  constructor() {
    super('Offline migration could not read all records');
  }
}

export enum AddResult {
  newCode = 0,
  duplicate = 1,
  updateCode = 2,
}

/** ASCII-lowercase, natural (numeric-aware) comparison for sorting. */
export function compareAsciiLowerCaseNatural(a: string, b: string): number {
  return naturalCompare(a.toLowerCase(), b.toLowerCase());
}

function naturalCompare(a: string, b: string): number {
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    const ca = a.charCodeAt(i);
    const cb = b.charCodeAt(j);
    const da = ca >= 48 && ca <= 57;
    const db = cb >= 48 && cb <= 57;
    if (da && db) {
      let na = 0;
      let nb = 0;
      while (i < a.length && a.charCodeAt(i) >= 48 && a.charCodeAt(i) <= 57) {
        na = na * 10 + (a.charCodeAt(i) - 48);
        i++;
      }
      while (j < b.length && b.charCodeAt(j) >= 48 && b.charCodeAt(j) <= 57) {
        nb = nb * 10 + (b.charCodeAt(j) - 48);
        j++;
      }
      if (na !== nb) {
        return na < nb ? -1 : 1;
      }
      continue;
    }
    if (ca !== cb) {
      return ca < cb ? -1 : 1;
    }
    i++;
    j++;
  }
  return (a.length - i) - (b.length - j);
}

export class CodeStore {
  private static instanceValue: CodeStore | undefined = undefined;

  static get instance(): CodeStore {
    if (CodeStore.instanceValue === undefined) {
      CodeStore.instanceValue = new CodeStore();
    }
    return CodeStore.instanceValue;
  }

  private constructor() {
  }

  private cacheCodes: Map<number, Code> = new Map<number, Code>();

  async getAllCodes(mode?: AccountMode, sortCodes: boolean = true): Promise<Code[]> {
    this.cacheCodes.clear();
    const effectiveMode: AccountMode = mode === undefined ? await AuthenticatorService.instance.getAccountMode() : mode;
    const entities: EntityResult[] = await AuthenticatorService.instance.getEntities(effectiveMode);
    const codes: Code[] = [];
    for (let i = 0; i < entities.length; i++) {
      const entity = entities[i];
      const code = this.parseEntity(entity);
      codes.push(code);
      this.cacheCodes.set(entity.generatedID, code);
    }
    if (sortCodes) {
      codes.sort((a: Code, b: Code) => {
        if (b.isPinned && !a.isPinned) {
          return 1;
        }
        if (!b.isPinned && a.isPinned) {
          return -1;
        }
        const issuerCmp = compareAsciiLowerCaseNatural(a.issuer, b.issuer);
        if (issuerCmp !== 0) {
          return issuerCmp;
        }
        return compareAsciiLowerCaseNatural(a.account, b.account);
      });
    }
    return codes;
  }

  private parseEntity(entity: EntityResult): Code {
    let code: Code | undefined = undefined;
    try {
      const trimmed: string = entity.rawData.trim();
      if (trimmed.length === 0) {
        const parseError = new CodeParseError('empty', entity.rawData);
        code = Code.withError(parseError.toString(), entity.rawData);
      } else if (trimmed.startsWith('"')) {
        const decodedStr: string = JSON.parse(trimmed) as string;
        if (decodedStr.startsWith('otpauth://')) {
          code = Code.fromOTPAuthUrl(decodedStr);
        }
      } else {
        const decoded: Record<string, Object> = JSON.parse(trimmed) as Record<string, Object>;
        const rawData = decoded['rawData'];
        if (rawData !== undefined) {
          code = Code.fromExportJson(decoded);
        }
      }
      if (code === undefined) {
        const parseError = new CodeParseError('unsupported', entity.rawData);
        code = Code.withError(parseError.toString(), entity.rawData);
      }
    } catch (e) {
      const err = e as Error;
      const parseError = CodeParseError.from(err, entity.rawData);
      Logger.warn('Could not parse stored code');
      code = Code.withError(parseError.toString(), entity.rawData);
    }
    code.generatedID = entity.generatedID;
    code.hasSynced = entity.hasSynced;
    return code;
  }

  async addCode(code: Code, shouldSync: boolean = true, mode?: AccountMode,
    existingAllCodes?: Code[]): Promise<AddResult> {
    const effectiveMode: AccountMode = mode === undefined ? await AuthenticatorService.instance.getAccountMode() : mode;
    const allCodes: Code[] = existingAllCodes === undefined ? await this.getAllCodes(effectiveMode) : existingAllCodes;
    let isExistingCode: boolean = false;
    let hasSameCode: boolean = false;
    for (let i = 0; i < allCodes.length; i++) {
      const existingCode = allCodes[i];
      if (existingCode.hasError) {
        continue;
      }
      if (code.generatedID !== undefined && existingCode.generatedID === code.generatedID) {
        isExistingCode = true;
      } else if (existingCode.equals(code)) {
        hasSameCode = true;
      }
    }
    if (!isExistingCode && hasSameCode) {
      return AddResult.duplicate;
    }
    if (isExistingCode) {
      await AuthenticatorService.instance.updateEntry(code.generatedID as number, code.toOTPAuthUrlFormat(),
        shouldSync, effectiveMode);
    } else {
      code.generatedID = await AuthenticatorService.instance.addEntry(code.toOTPAuthUrlFormat(), shouldSync,
        effectiveMode);
    }
    EventBus.fire(Events.CODES_UPDATED, null);
    return isExistingCode ? AddResult.updateCode : AddResult.newCode;
  }

  async removeCode(code: Code, mode?: AccountMode): Promise<void> {
    const effectiveMode: AccountMode = mode === undefined ? await AuthenticatorService.instance.getAccountMode() : mode;
    await AuthenticatorService.instance.deleteEntry(code.generatedID as number, effectiveMode);
    EventBus.fire(Events.CODES_UPDATED, null);
  }

  /** Reorder persistence: writes display.position (upstream saveUpadedIndexes). */
  async saveUpadedIndexes(codes: Code[], mode: AccountMode): Promise<boolean> {
    const existingAllCodes: Code[] = await this.getAllCodes(mode);
    const existingPosition: Map<number, number> = new Map<number, number>();
    for (let i = 0; i < existingAllCodes.length; i++) {
      const c = existingAllCodes[i];
      if (c.hasError || c.isTrashed) {
        continue;
      }
      existingPosition.set(c.generatedID as number, c.display.position);
    }
    let changedCount: number = 0;
    for (let i = 0; i < codes.length; i++) {
      const code = codes[i];
      const newIndex = codes.indexOf(code);
      const oldIndex = existingPosition.get(code.generatedID as number);
      if (oldIndex !== undefined && oldIndex !== newIndex) {
        const updated = code.copyWith(undefined, undefined, undefined, undefined, undefined,
          undefined, undefined, undefined,
          code.display.copyWith(undefined, undefined, undefined, undefined, undefined, undefined, newIndex));
        await this.addCode(updated, false, mode, existingAllCodes);
        changedCount++;
      }
    }
    if (changedCount > 0 && mode === AccountMode.online) {
      AuthenticatorService.instance.onlineSync();
    }
    return true;
  }

  private offlineImportInFlight: Promise<OfflineMigrationResult> | undefined = undefined;
  // Presentation-only progress: the initial check and an empty-source online
  // sync are not offline migration. Never use this flag for data decisions.
  private offlineMigrationRunning: boolean = false;
  private offlineMigrationRevision: number = -1;

  isOfflineMigrationRunning(): boolean {
    return this.offlineMigrationRunning &&
      this.offlineMigrationRevision === Configuration.instance.getAccountRevision() &&
      Configuration.instance.hasConfiguredAccount();
  }

  /** Home entry/retry share one operation; no overlapping imports. */
  importOfflineCodes(): Promise<OfflineMigrationResult> {
    if (this.offlineImportInFlight !== undefined) {
      return this.offlineImportInFlight;
    }
    const task = this.runOfflineImport();
    this.offlineImportInFlight = task;
    task.finally(() => {
      this.offlineImportInFlight = undefined;
      this.offlineMigrationRunning = false;
      EventBus.fire(Events.OFFLINE_MIGRATION_CHANGED, null);
    });
    return task;
  }

  private assertMigrationSession(revision: number): void {
    if (Configuration.instance.getAccountRevision() !== revision ||
      !Configuration.instance.hasConfiguredAccount()) {
      throw new Error('Migration account changed');
    }
  }

  /** Pinned import comparison, intentionally narrower than Code.equals. */
  private migrationEquivalent(a: Code, b: Code): boolean {
    return a.issuer === b.issuer && a.account === b.account && a.secret === b.secret;
  }

  /** Full server evidence, without advancing the normal sync cursor. Raw page
   * length includes tombstones. Overlap the boundary microsecond to include ties.
   * A saturated timestamp bucket fails closed instead of skipping possible matches.
   */
  private async migrationServerCodes(revision: number, key: Uint8Array): Promise<Code[]> {
    const live: Map<string, AuthEntity> = new Map<string, AuthEntity>();
    let since: number = 0;
    const limit: number = 5000;
    while (true) {
      this.assertMigrationSession(revision);
      const pair = await AuthenticatorGateway.getDiff(since, limit, true);
      this.assertMigrationSession(revision);
      const page = pair[0];
      let maxTime = since;
      for (let i = 0; i < page.length; i++) {
        const e = page[i];
        if (!e.id || !Number.isSafeInteger(e.updatedAt) || e.updatedAt <= since) {
          throw new Error('Invalid migration diff');
        }
        maxTime = Math.max(maxTime, e.updatedAt);
        if (e.isDeleted) {
          live.delete(e.id);
        } else {
          live.set(e.id, e);
        }
      }
      if (page.length < limit) {
        break;
      }
      if (maxTime - 1 <= since) {
        throw new Error('Migration diff cannot advance safely');
      }
      since = maxTime - 1;
    }
    const codes: Code[] = [];
    const entities: AuthEntity[] = Array.from(live.values());
    for (let i = 0; i < entities.length; i++) {
      const e = entities[i];
      try {
        const decrypted = await CryptoUtil.decryptData(CryptoUtil.base642bin(e.encryptedData as string),
          key, CryptoUtil.base642bin(e.header as string));
        const text = new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(decrypted);
        const code = this.parseEntity(new EntityResult(0, text, true));
        if (code.hasError) {
          throw new MigrationUnreadableError();
        }
        codes.push(code);
      } catch (err) {
        throw new MigrationUnreadableError();
      }
    }
    this.assertMigrationSession(revision);
    return codes;
  }

  private async runOfflineImport(): Promise<OfflineMigrationResult> {
    const config = Configuration.instance;
    const revision = config.getAccountRevision();
    try {
      if (!config.hasConfiguredAccount()) {
        return 'complete';
      }
      // Logout clears the ordinary opt-in flag, but preserves offline rows/key.
      // Existing source data is therefore authoritative for migration eligibility.
      const sources: LocalAuthEntity[] = await OfflineAuthenticatorDB.getAll();
      if (sources.length === 0) {
        this.assertMigrationSession(revision);
        await AuthenticatorService.instance.onlineSync();
        return 'complete';
      }
      this.assertMigrationSession(revision);
      this.offlineMigrationRevision = revision;
      this.offlineMigrationRunning = true;
      EventBus.fire(Events.OFFLINE_MIGRATION_CHANGED, null);
      if (config.getOfflineSecretKey() === undefined) {
        return 'unreadable';
      }
      const offline = await this.getAllCodes(AccountMode.offline, false);
      if (offline.some((c: Code) => c.hasError)) {
        return 'unreadable';
      }
      this.assertMigrationSession(revision);
      if (!await AuthenticatorService.instance.onlineSync()) {
        return 'retry';
      }
      this.assertMigrationSession(revision);
      const userID = config.getUserId();
      if (userID === undefined) {
        return 'retry';
      }
      const scope = JSON.stringify([config.getHttpEndpoint(), userID]);
      const key = await AuthenticatorService.instance.getOrCreateAuthDataKey(AccountMode.online);
      this.assertMigrationSession(revision);
      let online = await this.migrationServerCodes(revision, key);
      for (let i = 0; i < sources.length; i++) {
        const source = sources[i];
        const code = offline.find((c: Code) => c.generatedID === source.generatedID);
        if (code === undefined) {
          return 'retry';
        }
        // The parser performed a second read. Reject edits between snapshots.
        const current = await OfflineAuthenticatorDB.getEntryByID(source.generatedID);
        this.assertMigrationSession(revision);
        if (current === undefined || current.encryptedData !== source.encryptedData || current.header !== source.header) {
          return 'retry';
        }
        if (!online.some((c: Code) => this.migrationEquivalent(c, code))) {
          const attempted = await OfflineMigrationJournal.hasAttempt(scope, source.generatedID);
          this.assertMigrationSession(revision);
          if (attempted) {
            return 'uncertain';
          }
          const encrypted = await CryptoUtil.encryptData(CryptoUtil.strToBin(code.toOTPAuthUrlFormat()), key);
          this.assertMigrationSession(revision);
          await OfflineMigrationJournal.recordAttempt(scope, source.generatedID, source.header);
          this.assertMigrationSession(revision);
          // Never stage an unsynced online row that normal sync could replay.
          // The pinned server generates IDs and offers no idempotency key.
          // Interrupted dispatch stays uncertain until a pull proves success.
          try {
            const created = await AuthenticatorGateway.createEntity(
              CryptoUtil.bin2base64(encrypted.encryptedData as Uint8Array),
              CryptoUtil.bin2base64(encrypted.header as Uint8Array));
            if (!created.id) {
              return 'uncertain';
            }
          } catch (err) {
            return 'uncertain';
          }
          this.assertMigrationSession(revision);
          if (!await AuthenticatorService.instance.onlineSync()) {
            return 'retry';
          }
          this.assertMigrationSession(revision);
          online = await this.migrationServerCodes(revision, key);
          if (!online.some((c: Code) => this.migrationEquivalent(c, code))) {
            return 'uncertain';
          }
        }
        // Normal sync preserves the pin's tombstone pagination quirk. If its
        // cursor has not reached this server-confirmed code yet, retain the
        // source and let a later retry advance it; never show false completion.
        const localOnline = await this.getAllCodes(AccountMode.online, false);
        this.assertMigrationSession(revision);
        if (!localOnline.some((c: Code) => !c.hasError && c.hasSynced && this.migrationEquivalent(c, code))) {
          return 'retry';
        }
        const removed = await OfflineAuthenticatorDB.deleteUnchanged(source);
        if (removed !== 1) {
          return 'retry';
        }
        // Ledger cleanup follows source deletion. A failure leaves a harmless
        // record, never permission to repeat a possibly committed request.
        await OfflineMigrationJournal.remove(scope, source.generatedID);
      }
      EventBus.fire(Events.CODES_UPDATED, null);
      return 'complete';
    } catch (err) {
      if (config.getAccountRevision() !== revision || !config.hasConfiguredAccount()) {
        return 'cancelled';
      }
      if (err instanceof MigrationUnreadableError || err instanceof UnreadableAuthenticatorDataError) {
        return 'unreadable';
      }
      Logger.warn('Offline migration paused; source data retained');
      return 'retry';
    }
  }

  /** Export lines (toOTPAuthUrlFormat), unsorted, skipping errors. */
  async getCodesForExport(): Promise<string> {
    const codes: Code[] = await this.getAllCodes(undefined, false);
    let data: string = '';
    for (let i = 0; i < codes.length; i++) {
      if (codes[i].hasError) {
        continue;
      }
      data += `${codes[i].toOTPAuthUrlFormat()}\n`;
    }
    return data;
  }
}
