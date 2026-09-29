/**
 * AuthenticatorDB — online token database (`ente.authenticator.db`),
 * mirroring upstream `mobile/apps/auth/lib/store/authenticator_db.dart`.
 */
import { common } from '@kit.AbilityKit';
import { EntitiesTable } from './EntitiesTable';
import { AuthEntity, LocalAuthEntity } from '../models/AuthenticatorEntities';

export class AuthenticatorDB {
  private static table: EntitiesTable = new EntitiesTable();

  static async init(context: common.Context): Promise<void> {
    await AuthenticatorDB.table.init(context, 'ente.authenticator.db');
  }

  static async insert(encData: string, header: string): Promise<number> {
    return AuthenticatorDB.table.insert(encData, header);
  }

  static async updateEntry(generatedID: number, encData: string, header: string): Promise<number> {
    return AuthenticatorDB.table.updateEntry(generatedID, encData, header);
  }

  static async insertOrReplace(entities: AuthEntity[]): Promise<void> {
    return AuthenticatorDB.table.insertOrReplace(entities);
  }

  static async getEntryByID(genID: number): Promise<LocalAuthEntity | undefined> {
    return AuthenticatorDB.table.getEntryByID(genID);
  }

  static async getAll(): Promise<LocalAuthEntity[]> {
    return AuthenticatorDB.table.getAll();
  }

  static async updateLocalEntity(entity: LocalAuthEntity): Promise<void> {
    return AuthenticatorDB.table.updateLocalEntity(entity);
  }

  static async deleteByIDs(generatedIDs?: number[], ids?: string[]): Promise<void> {
    return AuthenticatorDB.table.deleteByIDs(generatedIDs, ids);
  }

  static async removeSyncedData(): Promise<number> {
    return AuthenticatorDB.table.removeSyncedData();
  }

  static async getNeedSyncCount(): Promise<number> {
    return AuthenticatorDB.table.getNeedSyncCount();
  }

  static async clearTable(): Promise<void> {
    return AuthenticatorDB.table.clearTable();
  }
}