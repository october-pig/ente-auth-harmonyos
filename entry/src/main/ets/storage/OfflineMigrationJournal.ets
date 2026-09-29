/** Local-only attempt ledger. Never contains OTP plaintext or keys.
 * Separate from ordinary preferences/online DB so logout cannot erase an
 * uncertain POST and cause it to be submitted again after signing back in.
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

export class OfflineMigrationJournal {
  private static store: relationalStore.RdbStore | undefined = undefined;

  static async init(context: common.Context): Promise<void> {
    if (OfflineMigrationJournal.store === undefined) {
      OfflineMigrationJournal.store = await relationalStore.getRdbStore(context, {
        name: 'ente.offline_migration.db', securityLevel: relationalStore.SecurityLevel.S1,
      });
      await OfflineMigrationJournal.store.executeSql('CREATE TABLE IF NOT EXISTS attempts (' +
        '_generatedID INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, ' +
        'scope TEXT NOT NULL, sourceID INTEGER NOT NULL, sourceHeader TEXT NOT NULL, ' +
        'UNIQUE(scope, sourceID))');
    }
  }

  private static db(): relationalStore.RdbStore {
    if (OfflineMigrationJournal.store === undefined) {
      throw new Error('Migration journal not initialized');
    }
    return OfflineMigrationJournal.store;
  }

  private static predicate(scope: string, sourceID: number): relationalStore.RdbPredicates {
    const p = new relationalStore.RdbPredicates('attempts');
    p.equalTo('scope', scope).equalTo('sourceID', sourceID);
    return p;
  }

  static async hasAttempt(scope: string, sourceID: number): Promise<boolean> {
    const rows = await OfflineMigrationJournal.db().query(OfflineMigrationJournal.predicate(scope, sourceID));
    try {
      return rows.goToFirstRow();
    } finally {
      rows.close();
    }
  }

  /** Await the durable insert BEFORE dispatch. A crash in between fails closed. */
  static async recordAttempt(scope: string, sourceID: number, sourceHeader: string): Promise<void> {
    const inserted = await OfflineMigrationJournal.db().insert('attempts', { scope: scope, sourceID: sourceID, sourceHeader: sourceHeader });
    if (inserted <= 0) {
      throw new Error('Migration attempt was not persisted');
    }
  }

  static async remove(scope: string, sourceID: number): Promise<void> {
    await OfflineMigrationJournal.db().delete(OfflineMigrationJournal.predicate(scope, sourceID));
  }
}
