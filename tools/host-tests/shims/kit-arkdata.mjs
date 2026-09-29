/**
 * kit-arkdata.mjs — host shim for `@kit.ArkData` (`preferences`, `relationalStore`).
 *
 * `preferences` is a straightforward in-memory key/value store.
 *
 * `relationalStore` is a deliberately faithful *subset* of the ArkData RDB API
 * (which is itself a SQLite wrapper). It implements only what the port uses,
 * but it models the two semantics that actually matter for correctness:
 *
 *   1. `INSERT OR REPLACE` (ConflictResolution.ON_CONFLICT_REPLACE) resolves a
 *      UNIQUE conflict by DELETING the conflicting row and INSERTING a new one,
 *      so the AUTOINCREMENT primary key (`_generatedID`) CHANGES. Upstream
 *      relies on this. See SYNC_SPEC.md.
 *   2. INTEGER columns round-trip as JS numbers, preserving microsecond
 *      timestamps exactly (they are < 2^53).
 *
 * Anything outside the supported subset throws loudly instead of silently
 * returning wrong data.
 */

// ------------------------------------------------------------------ preferences

const prefsStores = new Map();
/**
 * Every PreferencesImpl ever handed out. The production classes cache the
 * instance they got from `getPreferences`, so resetting must clear the
 * instances IN PLACE rather than dropping the registry entry - otherwise the
 * production code keeps writing to an orphaned store and state bleeds between
 * tests.
 */
const allPrefsInstances = new Set();

/**
 * Durability accounting.
 *
 * Documented platform semantics (MCP `js-apis-data-preferences`, cross-checked
 * against `@ohos.data.preferences.d.ts:797-821` / `:946-968`):
 *   - `put`/`delete`/`clear` write to the IN-MEMORY Preferences instance only.
 *   - `flush` is what "flushes the data in this Preferences instance to the
 *     persistent file".
 * ⇒ `put` without `flush` is not durable, and an un-awaited `put`+`flush` pair
 * can be lost to a process death or the next state transition.
 *
 * `writeSeq` counts write operations that have started; `flushedSeq` advances
 * when a `flush` actually completes. `__pendingWrites()` is the difference, so a
 * fire-and-forget write is OBSERVABLE: `put` mutates the store synchronously but
 * `flush` is reached only after an `await`, so in the same tick the write is
 * still pending.
 *
 * `flush` deliberately crosses a real macrotask boundary (`setImmediate`). If it
 * resolved within the same microtask drain, a non-awaited `put`+`flush` would
 * look settled by the time the caller's next microtask ran, and the bug would be
 * invisible again — which is exactly how the 238 pre-existing tests missed it.
 */
let writeSeq = 0;
let flushedSeq = 0;
let flushGeneration = 0;

class PreferencesImpl {
  constructor(name) {
    this.name = name;
    this.map = new Map();
    allPrefsInstances.add(this);
  }
  async get(key, defValue) {
    return this.map.has(key) ? this.map.get(key) : defValue;
  }
  async put(key, value) {
    this.map.set(key, value);
    writeSeq++;
  }
  async has(key) {
    return this.map.has(key);
  }
  // SDK @ohos.data.preferences.d.ts:708: all KV pairs from this instance.
  async getAll() {
    return Object.fromEntries(this.map);
  }
  async delete(key) {
    this.map.delete(key);
    writeSeq++;
  }
  async clear() {
    this.map.clear();
    writeSeq++;
  }
  async flush() {
    const generation = flushGeneration;
    const target = writeSeq;
    await new Promise((resolve) => setImmediate(resolve));
    // A reset happened while this flush was in flight: it belongs to a previous
    // test and must not settle the current one's accounting.
    if (generation !== flushGeneration) return;
    if (target > flushedSeq) flushedSeq = target;
  }
  on() {}
  off() {}
}

export const preferences = {
  async getPreferences(_context, name) {
    if (!prefsStores.has(name)) prefsStores.set(name, new PreferencesImpl(name));
    return prefsStores.get(name);
  },
  deletePreferences: async (_context, name) => {
    prefsStores.delete(name);
  },
  removePreferencesFromCache: async () => {},
};

/** Test helper: wipe all preference stores IN PLACE between tests. */
export function __resetPreferences() {
  for (const s of allPrefsInstances) s.map.clear();
  flushGeneration++;
  writeSeq = 0;
  flushedSeq = 0;
}

/**
 * Test helper: write operations whose `flush` has not yet completed.
 * 0 means every write issued so far is durable.
 */
export function __pendingWrites() {
  return writeSeq - flushedSeq;
}

// --------------------------------------------------------------- relationalStore

export const ConflictResolution = Object.freeze({
  ON_CONFLICT_NONE: 0,
  ON_CONFLICT_ROLLBACK: 1,
  ON_CONFLICT_ABORT: 2,
  ON_CONFLICT_FAIL: 3,
  ON_CONFLICT_IGNORE: 4,
  ON_CONFLICT_REPLACE: 5,
});

export const SecurityLevel = Object.freeze({ S1: 1, S2: 2, S3: 3, S4: 4 });

const CREATE_RE = /^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(([\s\S]*)\)\s*;?\s*$/i;

function parseCreate(sql) {
  const m = CREATE_RE.exec(sql);
  if (!m) throw new Error(`[relationalStore shim] unsupported CREATE: ${sql}`);
  const table = m[1];
  const body = m[2];
  const cols = [];
  let pk = null;
  const uniques = [];
  // split top-level commas
  const parts = [];
  let depth = 0;
  let cur = '';
  for (const ch of body) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) {
      parts.push(cur);
      cur = '';
    } else cur += ch;
  }
  if (cur.trim()) parts.push(cur);
  for (const raw of parts) {
    const p = raw.trim();
    if (/^UNIQUE\s*\(/i.test(p)) {
      const inner = /\((.*)\)/.exec(p)[1];
      uniques.push(inner.split(',').map((s) => s.trim()));
      continue;
    }
    if (/^PRIMARY\s+KEY/i.test(p) || /^FOREIGN\s+KEY/i.test(p) || /^CONSTRAINT/i.test(p)) continue;
    const name = p.split(/\s+/)[0];
    const isPk = /\bPRIMARY\s+KEY\b/i.test(p);
    const autoinc = /\bAUTOINCREMENT\b/i.test(p);
    const notnull = /\bNOT\s+NULL\b/i.test(p);
    cols.push({ name, isPk, autoinc, notnull, raw: p });
    if (isPk) pk = name;
  }
  return { table, cols, pk, uniques };
}

class ResultSet {
  constructor(columnNames, rows) {
    this.columnNames = columnNames;
    this._rows = rows;
    this._idx = -1;
    this._closed = false;
  }
  get rowCount() {
    return this._rows.length;
  }
  getColumnIndex(name) {
    const i = this.columnNames.indexOf(name);
    if (i < 0) throw new Error(`[relationalStore shim] no such column: ${name}`);
    return i;
  }
  goToFirstRow() {
    this._idx = this._rows.length > 0 ? 0 : -1;
    return this._idx === 0;
  }
  goToNextRow() {
    if (this._idx + 1 >= this._rows.length) return false;
    this._idx++;
    return true;
  }
  goToRow(i) {
    if (i < 0 || i >= this._rows.length) return false;
    this._idx = i;
    return true;
  }
  getValue(idx) {
    if (this._idx < 0) throw new Error('[relationalStore shim] cursor not positioned');
    return this._rows[this._idx][idx];
  }
  getString(idx) {
    return String(this.getValue(idx));
  }
  getLong(idx) {
    return Number(this.getValue(idx));
  }
  isColumnNull(idx) {
    return this.getValue(idx) === null;
  }
  close() {
    this._closed = true;
  }
}

class RdbPredicates {
  constructor(table) {
    this.table = table;
    this.conditions = [];
    this.order = null;
  }
  equalTo(field, value) {
    this.conditions.push({ op: 'eq', field, value });
    return this;
  }
  notEqualTo(field, value) {
    this.conditions.push({ op: 'ne', field, value });
    return this;
  }
  orderByAsc(field) {
    this.order = { field, dir: 1 };
    return this;
  }
  orderByDesc(field) {
    this.order = { field, dir: -1 };
    return this;
  }
  _match(row) {
    for (const c of this.conditions) {
      const v = row[c.field];
      if (c.op === 'eq' && v !== c.value) return false;
      if (c.op === 'ne' && v === c.value) return false;
    }
    return true;
  }
}

class Table {
  constructor(def) {
    this.def = def;
    this.rows = [];
    this.nextRowId = 1;
  }
  rowIdCol() {
    return this.def.pk;
  }
  makeRow(values) {
    const row = {};
    for (const c of this.def.cols) row[c.name] = null;
    for (const [k, v] of Object.entries(values)) {
      if (!(k in row)) throw new Error(`[relationalStore shim] unknown column "${k}" in ${this.def.table}`);
      row[k] = v;
    }
    for (const c of this.def.cols) {
      if (c.notnull && row[c.name] === null && !c.isPk) {
        throw new Error(`[relationalStore shim] NOT NULL constraint failed: ${this.def.table}.${c.name}`);
      }
    }
    return row;
  }
  findUniqueConflict(row) {
    for (const cols of this.def.uniques) {
      // SQLite: NULLs are DISTINCT in a UNIQUE index, so several rows with a
      // NULL id coexist. Mirroring this matters: a freshly scanned code is
      // inserted with id = NULL, and many such rows must be allowed.
      if (cols.some((c) => row[c] === null || row[c] === undefined)) continue;
      const cand = this.rows.find((r) => cols.every((c) => r[c] === row[c]));
      if (cand) return cand;
    }
    return null;
  }
  insert(values, conflict) {
    const row = this.makeRow(values);
    const conflictRow = this.findUniqueConflict(row);
    if (conflictRow) {
      if (conflict === ConflictResolution.ON_CONFLICT_REPLACE) {
        // SQLite INSERT OR REPLACE: delete conflicting row(s), insert a new one.
        this.rows = this.rows.filter((r) => r !== conflictRow);
      } else if (conflict === ConflictResolution.ON_CONFLICT_IGNORE) {
        return 0;
      } else {
        throw new Error(`[relationalStore shim] UNIQUE constraint failed: ${this.def.table}`);
      }
    }
    row[this.rowIdCol()] = this.nextRowId++;
    this.rows.push(row);
    return row[this.rowIdCol()];
  }
  update(values, predicates, conflict) {
    let n = 0;
    for (const row of [...this.rows]) {
      if (!predicates._match(row)) continue;
      const merged = { ...row, ...values };
      const conflictRow = this.findUniqueConflict(merged);
      if (conflictRow && conflictRow !== row) {
        if (conflict === ConflictResolution.ON_CONFLICT_REPLACE) {
          this.rows = this.rows.filter((r) => r !== conflictRow);
        } else {
          throw new Error(`[relationalStore shim] UNIQUE constraint failed on update: ${this.def.table}`);
        }
      }
      Object.assign(row, values);
      n++;
    }
    return n;
  }
  delete(predicates) {
    const before = this.rows.length;
    this.rows = this.rows.filter((r) => !predicates._match(r));
    return before - this.rows.length;
  }
  selectAll() {
    return this.rows.map((r) => ({ ...r }));
  }
}

class RdbStore {
  constructor(name) {
    this.name = name;
    this.tables = new Map();
    this._txDepth = 0;
    this._txSnapshot = null;
  }
  async executeSql(sql, _bindArgs) {
    const s = sql.trim();
    const create = CREATE_RE.exec(s);
    if (create) {
      const def = parseCreate(s);
      if (!this.tables.has(def.table)) this.tables.set(def.table, new Table(def));
      return;
    }
    const del = /^DELETE\s+FROM\s+(\w+)\s*;?\s*$/i.exec(s);
    if (del) {
      const t = this.tables.get(del[1]);
      if (!t) throw new Error(`[relationalStore shim] no table ${del[1]}`);
      t.rows = [];
      return;
    }
    throw new Error(`[relationalStore shim] unsupported executeSql: ${s}`);
  }
  _table(name) {
    const t = this.tables.get(name);
    if (!t) throw new Error(`[relationalStore shim] no table "${name}"`);
    return t;
  }
  async insert(table, values, conflict = ConflictResolution.ON_CONFLICT_NONE) {
    return this._table(table).insert(values, conflict);
  }
  async update(values, predicates, conflict = ConflictResolution.ON_CONFLICT_NONE) {
    return this._table(predicates.table).update(values, predicates, conflict);
  }
  async delete(predicates) {
    return this._table(predicates.table).delete(predicates);
  }
  async query(predicates) {
    const t = this._table(predicates.table);
    let rows = t.selectAll().filter((r) => predicates._match(r));
    if (predicates.order) {
      const { field, dir } = predicates.order;
      rows.sort((a, b) => (a[field] > b[field] ? dir : a[field] < b[field] ? -dir : 0));
    }
    return new ResultSet(t.def.cols.map((c) => c.name), rows.map((r) => t.def.cols.map((c) => r[c.name])));
  }
  async querySql(sql, _bindArgs) {
    const s = sql.trim().replace(/;$/, '');
    const countRe = /^SELECT\s+COUNT\(\*\)\s+as\s+(\w+)\s+from\s+(\w+)(?:\s+WHERE\s+(.+))?$/i;
    const cm = countRe.exec(s);
    if (cm) {
      const t = this._table(cm[2]);
      let rows = t.selectAll();
      if (cm[3]) {
        const wm = /^(\w+)\s*=\s*(.+)$/.exec(cm[3].trim());
        if (!wm) throw new Error(`[relationalStore shim] unsupported WHERE: ${cm[3]}`);
        const field = wm[1];
        const val = Number(wm[2]);
        rows = rows.filter((r) => r[field] === val);
      }
      return new ResultSet([cm[1]], [[rows.length]]);
    }
    const allRe = /^SELECT\s+\*\s+from\s+(\w+)\s*$/i.exec(s);
    if (allRe) {
      const t = this._table(allRe[1]);
      const rows = t.selectAll();
      return new ResultSet(t.def.cols.map((c) => c.name), rows.map((r) => t.def.cols.map((c) => r[c.name])));
    }
    throw new Error(`[relationalStore shim] unsupported querySql: ${s}`);
  }
  async beginTransaction() {
    if (this._txDepth === 0) {
      this._txSnapshot = [...this.tables.entries()].map(([k, t]) => [k, t.rows.map((r) => ({ ...r })), t.nextRowId]);
    }
    this._txDepth++;
  }
  async commit() {
    this._txDepth = Math.max(0, this._txDepth - 1);
    if (this._txDepth === 0) this._txSnapshot = null;
  }
  async rollBack() {
    if (this._txSnapshot) {
      for (const [k, rows, next] of this._txSnapshot) {
        const t = this.tables.get(k);
        if (t) {
          t.rows = rows;
          t.nextRowId = next;
        }
      }
    }
    this._txDepth = 0;
    this._txSnapshot = null;
  }
  async close() {}
}

const rdbStores = new Map();
/** Every RdbStore ever handed out (the production code caches these too). */
const allRdbStores = new Set();

export const relationalStore = {
  ConflictResolution,
  SecurityLevel,
  RdbPredicates,
  async getRdbStore(_context, config) {
    const name = typeof config === 'string' ? config : config.name;
    if (!rdbStores.has(name)) {
      const s = new RdbStore(name);
      rdbStores.set(name, s);
      allRdbStores.add(s);
    }
    return rdbStores.get(name);
  },
  async deleteRdbStore(_context, name) {
    rdbStores.delete(name);
  },
};

/** Test helper: empty every table IN PLACE between tests. */
export function __resetRdb() {
  for (const s of allRdbStores) {
    for (const t of s.tables.values()) {
      t.rows = [];
      t.nextRowId = 1;
    }
    s._txDepth = 0;
    s._txSnapshot = null;
  }
}

export default { preferences, relationalStore, ConflictResolution, SecurityLevel };
