// Execute production filtering/state methods. No claim about ArkUI rendering.
import { stripTypeScriptTypes } from 'node:module';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { assert, assertEquals, describe, it } from '../framework.mjs';
const path = 'entry/src/main/ets/pages/HomePage.ets';
const source = process.env.HOME_UI_SOURCE_REF
  ? execFileSync('git', ['show', `${process.env.HOME_UI_SOURCE_REF}:${path}`], { encoding: 'utf8' })
  : readFileSync(new URL('../../../' + path, import.meta.url), 'utf8');
function method(name) {
  const start = source.indexOf(`${name}():`);
  assert(start >= 0, `missing production method ${name}`);
  const open = source.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  return stripTypeScriptTypes('function ' + source.slice(start, end));
}
function harness() {
  const state = {
    searchText: '', selectedTag: '', isTrashOpen: false, filteredCodes: [],
    selectedKeys: [], isSelectionMode: false,
    allCodes: [
      { issuer: 'Alpha', account: '', note: '', hasError: false, isTrashed: false, display: { tags: ['work'] } },
      { issuer: 'Beta', account: '', note: '', hasError: false, isTrashed: false, display: { tags: [] } },
      { issuer: 'Trashed', account: '', note: '', hasError: false, isTrashed: true, display: { tags: ['work'] } },
    ],
    sortCodes: codes => codes,
  };
  for (const name of ['applyFiltering', 'hasTrashedCodes', 'clearSelection']) {
    state[name] = new Function(method(name) + `; return ${name};`)().bind(state);
  }
  // Bind lazily so the baseline still exercises filtering, independent of the
  // new empty-trash recovery method's existence.
  state.reconcile = () => new Function(method('reconcileTrashFilter') + '; return reconcileTrashFilter;')().call(state);
  return state;
}
describe('Permanent Home search and conditional trash scope', () => {
  it('typing filters immediately without any search visibility flag or toolbar request', () => {
    const s = harness();
    s.searchText = 'Alpha'; s.applyFiltering();
    assertEquals(s.filteredCodes.length, 1);
    assertEquals(s.filteredCodes[0].issuer, 'Alpha');
    s.searchText = 'no match'; s.applyFiltering();
    assertEquals(s.filteredCodes.length, 0);
  });
  it('native clear restores the current tag or trash scope', () => {
    const s = harness();
    s.selectedTag = 'work';
    s.searchText = 'no match'; s.applyFiltering();
    assertEquals(s.filteredCodes.length, 0);
    s.searchText = ''; s.applyFiltering();
    assertEquals(s.filteredCodes.length, 1);
    assertEquals(s.filteredCodes[0].issuer, 'Alpha');
    s.isTrashOpen = true;
    s.searchText = 'no match'; s.applyFiltering();
    assertEquals(s.filteredCodes.length, 0);
    s.searchText = ''; s.applyFiltering();
    assertEquals(s.filteredCodes[0].issuer, 'Trashed');
    assert(s.isTrashOpen);
  });
  it('last trashed code removal returns to active scope and drops stale selection', () => {
    const s = harness();
    s.isTrashOpen = true; s.selectedKeys = ['removed']; s.isSelectionMode = true;
    s.allCodes = s.allCodes.filter(c => !c.isTrashed);
    s.reconcile(); s.applyFiltering();
    assert(!s.hasTrashedCodes()); assert(!s.isTrashOpen);
    assert(!s.isSelectionMode); assertEquals(s.selectedKeys.length, 0);
    assertEquals(s.filteredCodes.length, 2);
  });
  it('a no-match query does not hide a populated trash scope or clear selection', () => {
    const s = harness();
    s.isTrashOpen = true; s.selectedKeys = ['kept']; s.isSelectionMode = true;
    s.searchText = 'no match'; s.reconcile(); s.applyFiltering();
    assert(s.hasTrashedCodes()); assert(s.isTrashOpen);
    assertEquals(s.filteredCodes.length, 0);
    assertEquals(s.selectedKeys[0], 'kept');
  });
  it('unreadable entries alone do not retain an unreachable trash scope', () => {
    const s = harness();
    s.allCodes = [{ issuer: '', hasError: true, isTrashed: true }];
    s.isTrashOpen = true; s.reconcile();
    assert(!s.hasTrashedCodes()); assert(!s.isTrashOpen);
    assertEquals(s.allCodes.length, 1); // Error data is never discarded.
  });
});
