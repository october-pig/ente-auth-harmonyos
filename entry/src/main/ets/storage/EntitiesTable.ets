/**
 * Shared relationalStore table implementation for the entities schema,
 * parameterized by database name (used by AuthenticatorDB and
 * OfflineAuthenticatorDB). Mirrors the upstream sqflite implementations
 * (`mobile/apps/auth/lib/store/authenticator_db.dart` and
 * `offline_authenticator_db.dart`).
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AuthEntity, LocalAuthEntity } from '../models/AuthenticatorEntities';
import { toError } from '../utils/Errors';

const CREATE_SQL: string =
  'CREATE TABLE IF NOT EXISTS entities (' +
  '_generatedID INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, ' +
  'id TEXT, encryptedData TEXT NOT NULL, header TEXT NOT NULL, ' +
  'createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL, ' +
  'shouldSync INTEGER DEFAULT 0, UNIQUE(id))';

function microsNow(): number {
  return Date.now() * 1000;
}

export class EntitiesTable {
  private store: relationalStore.RdbStore | undefined = undefined;

  async init(context: common.Context, dbName: string): Promise<void> {
    if (this.store === undefined) {
      const config: relationalStore.StoreConfig = {
        name: dbName,
        securityLevel: relationalStore.SecurityLevel.S1,
      };
      this.store = await relationalStore.getRdbStore(context, config);
      await this.store.executeSql(CREATE_SQL);
    }
  }

  private requireStore(): relationalStore.RdbStore {
    if (this.store === undefined) {
      throw new Error('EntitiesTable not initialized');
    }
    return this.store;
  }

  async insert(encData: string, header: string): Promise<number> {
    const values: relationalStore.ValuesBucket = {
      'encryptedData': encData,
      'header': header,
      'shouldSync': 1,
      'createdAt': microsNow(),
      'updatedAt': microsNow(),
    };
    return this.requireStore().insert('entities', values);
  }

  async updateEntry(generatedID: number, encData: string, header: string): Promise<number> {
    const values: relationalStore.ValuesBucket = {
      'encryptedData': encData,
      'header': header,
      'shouldSync': 1,
      'updatedAt': microsNow(),
    };
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates('entities');
    predicates.equalTo('_generatedID', generatedID);
    return this.requireStore().update(values, predicates);
  }

  /** REPLACE by remote id; rows get a NEW _generatedID on conflict (upstream semantics). */
  async insertOrReplace(entities: AuthEntity[]): Promise<void> {
    const store = this.requireStore();
    await store.beginTransaction();
    try {
      for (let i = 0; i < entities.length; i++) {
        const e = entities[i];
        const values: relationalStore.ValuesBucket = {
          'id': e.id,
          'encryptedData': e.encryptedData === undefined ? '' : e.encryptedData,
          'header': e.header === undefined ? '' : e.header,
          'createdAt': e.createdAt,
          'updatedAt': e.updatedAt,
          'shouldSync': 0,
        };
        await store.insert('entities', values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
      }
      await store.commit();
    } catch (e) {
      await store.rollBack();
      throw toError(e);
    }
  }

  async getEntryByID(genID: number): Promise<LocalAuthEntity | undefined> {
    const predicates = new relationalStore.RdbPredicates('entities');
    predicates.equalTo('_generatedID', genID);
    const result = await this.requireStore().query(predicates);
    let entity: LocalAuthEntity | undefined = undefined;
    if (result.goToFirstRow()) {
      entity = this.rowToLocalEntity(result);
    }
    result.close();
    return entity;
  }

  private rowToLocalEntity(row: relationalStore.ResultSet): LocalAuthEntity {
    return LocalAuthEntity.fromMap(this.rowToMap(row));
  }

  private rowToMap(row: relationalStore.ResultSet): Record<string, Object> {
    const map: Record<string, Object> = {};
    const cols = row.columnNames;
    for (let i = 0; i < cols.length; i++) {
      const name = cols[i];
      map[name] = row.getValue(row.getColumnIndex(name)) as Object;
    }
    return map;
  }

  async getAll(): Promise<LocalAuthEntity[]> {
    const result = await this.requireStore().querySql('SELECT * from entities');
    const list: LocalAuthEntity[] = [];
    while (result.goToNextRow()) {
      list.push(this.rowToLocalEntity(result));
    }
    result.close();
    return list;
  }

  async updateLocalEntity(entity: LocalAuthEntity): Promise<void> {
    const values: relationalStore.ValuesBucket = {
      'encryptedData': entity.encryptedData,
      'header': entity.header,
      'createdAt': entity.createdAt,
      'updatedAt': entity.updatedAt,
      'shouldSync': entity.shouldSync ? 1 : 0,
    };
    if (entity.id !== undefined) {
      values['id'] = entity.id;
    }
    const predicates = new relationalStore.RdbPredicates('entities');
    predicates.equalTo('_generatedID', entity.generatedID);
    await this.requireStore().update(values, predicates,
      relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  async deleteByIDs(generatedIDs?: number[], ids?: string[]): Promise<void> {
    const store = this.requireStore();
    await store.beginTransaction();
    try {
      if (generatedIDs !== undefined) {
        for (let i = 0; i < generatedIDs.length; i++) {
          const p = new relationalStore.RdbPredicates('entities');
          p.equalTo('_generatedID', generatedIDs[i]);
          await store.delete(p);
        }
      }
      if (ids !== undefined) {
        for (let i = 0; i < ids.length; i++) {
          const p = new relationalStore.RdbPredicates('entities');
          p.equalTo('id', ids[i]);
          await store.delete(p);
        }
      }
      await store.commit();
    } catch (e) {
      await store.rollBack();
      throw toError(e);
    }
  }

  /** Conditional source cleanup; a concurrent edit must survive migration. */
  async deleteUnchanged(entity: LocalAuthEntity): Promise<number> {
    const p = new relationalStore.RdbPredicates('entities');
    p.equalTo('_generatedID', entity.generatedID);
    p.equalTo('encryptedData', entity.encryptedData);
    p.equalTo('header', entity.header);
    return this.requireStore().delete(p);
  }

  /** Deletes rows with shouldSync = 0 (only fully-synced rows). Returns affected count. */
  async removeSyncedData(): Promise<number> {
    const predicates = new relationalStore.RdbPredicates('entities');
    predicates.equalTo('shouldSync', 0);
    return this.requireStore().delete(predicates);
  }

  async getNeedSyncCount(): Promise<number> {
    const result = await this.requireStore().querySql('SELECT COUNT(*) as cnt from entities WHERE shouldSync = 1');
    let count = 0;
    if (result.goToFirstRow()) {
      const map = this.rowToMap(result);
      count = map['cnt'] as number;
    }
    result.close();
    return count;
  }

  async clearTable(): Promise<void> {
    await this.requireStore().executeSql('DELETE FROM entities');
  }
}
