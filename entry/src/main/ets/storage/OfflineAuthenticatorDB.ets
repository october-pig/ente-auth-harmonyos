/**
 * OfflineAuthenticatorDB — offline token database (`ente.offline_authenticator.db`),
 * mirroring upstream `mobile/apps/auth/lib/store/offline_authenticator_db.dart`.
 * Identical schema; no removeSyncedData/getNeedSyncCount (upstream parity).
 */
import { common } from '@kit.AbilityKit';
import { EntitiesTable } from './EntitiesTable';
import { LocalAuthEntity } from '../models/AuthenticatorEntities';
import { OfflineMigrationJournal } from './OfflineMigrationJournal';

export class OfflineAuthenticatorDB {
  private static table: EntitiesTable = new EntitiesTable();

  static async init(context: common.Context): Promise<void> {
    await OfflineAuthenticatorDB.table.init(context, 'ente.offline_authenticator.db');
    await OfflineMigrationJournal.init(context);
  }

  static async insert(encData: string, header: string): Promise<number> {
    return OfflineAuthenticatorDB.table.insert(encData, header);
  }

  static async updateEntry(generatedID: number, encData: string, header: string): Promise<number> {
    return OfflineAuthenticatorDB.table.updateEntry(generatedID, encData, header);
  }

  static async getEntryByID(genID: number): Promise<LocalAuthEntity | undefined> {
    return OfflineAuthenticatorDB.table.getEntryByID(genID);
  }

  static async getAll(): Promise<LocalAuthEntity[]> {
    return OfflineAuthenticatorDB.table.getAll();
  }

  static async updateLocalEntity(entity: LocalAuthEntity): Promise<void> {
    return OfflineAuthenticatorDB.table.updateLocalEntity(entity);
  }

  static async deleteByIDs(generatedIDs?: number[]): Promise<void> {
    return OfflineAuthenticatorDB.table.deleteByIDs(generatedIDs);
  }

  /** Delete only the exact source snapshot whose server representation was verified. */
  static async deleteUnchanged(entity: LocalAuthEntity): Promise<number> {
    return OfflineAuthenticatorDB.table.deleteUnchanged(entity);
  }

  static async clearTable(): Promise<void> {
    return OfflineAuthenticatorDB.table.clearTable();
  }
}
