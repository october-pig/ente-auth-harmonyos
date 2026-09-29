// Execute Home's actual orchestration and event methods, not ArkUI rendering.
// Service boundary is controlled so assertions run during the outstanding await.
import { stripTypeScriptTypes } from 'node:module';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { assert, assertEquals, describe, it } from '../framework.mjs';
const path = 'entry/src/main/ets/pages/HomePage.ets';
const source = process.env.HOME_MIGRATION_SOURCE_REF
  ? execFileSync('git', ['show', `${process.env.HOME_MIGRATION_SOURCE_REF}:${path}`], { encoding: 'utf8' })
  : readFileSync(new URL('../../../' + path, import.meta.url), 'utf8');
function member(marker) {
  const start = source.indexOf(marker);
  assert(start >= 0, `missing production member ${marker}`);
  const open = source.indexOf('{', start);
  let depth = 1, end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
  }
  return source.slice(start, end);
}
function harness() {
  let release;
  const operation = new Promise(resolve => { release = resolve; });
  const service = {
    running: false, calls: 0,
    isOfflineMigrationRunning() { return this.running; },
    importOfflineCodes() { this.calls++; return operation; },
  };
  const removals = [];
  const Events = { CODES_UPDATED: 'codes', HIDE_CODES_CHANGED: 'hide', OFFLINE_MIGRATION_CHANGED: 'migration' };
  const EventBus = { off: (type, fn) => removals.push([type, fn]) };
  // The predecessor has no event handler; keep its real migrate body runnable
  // so the primary regression fails on the visible banner, not a missing method.
  const listener = source.includes('private onMigrationChanged:')
    ? member('private onMigrationChanged:') + ';' : '';
  const code = stripTypeScriptTypes(`class HomeMethods {
    ${member('private async migrateOfflineCodes()')}
    ${member('aboutToDisappear()')}
    ${listener}
  }`);
  const HomeMethods = new Function('CodeStore', 'EventBus', 'Events', code + '; return HomeMethods;')({ instance: service }, EventBus, Events);
  const state = new HomeMethods();
  Object.assign(state, {
    active: true, generation: 1, currentGeneration: 1, loadRequest: 0, loads: 0,
    migrationInFlight: false, migrationRunning: false, migrationStatus: '',
    onCodesUpdated() {}, onHideCodesChanged() {},
    isCurrentAppearance(generation) { return this.active && generation === this.currentGeneration; },
    loadCodes() { this.loads++; },
  });
  return { state, service, removals, finish: result => { service.running = false; release(result); } };
}
describe('Home migration banner — executable UI orchestration', () => {
  it('does not show a migration banner while the empty-source online sync awaits', async () => {
    const h = harness();
    const work = h.state.migrateOfflineCodes();
    try {
      assertEquals(h.state.migrationRunning, false, 'Home must not label the entire await as migration');
      await h.state.migrateOfflineCodes();
      assertEquals(h.service.calls, 1, 'silent checking still coalesces repeated requests');
    } finally { h.finish('complete'); await work; }
    assertEquals(h.state.migrationInFlight, false);
    assertEquals(h.state.migrationStatus, '');
  });
  it('picks up an already-running migration and reacts to actual progress events', async () => {
    const h = harness(); h.service.running = true;
    const work = h.state.migrateOfflineCodes();
    try {
      assert(h.state.migrationRunning);
      h.service.running = false; h.state.onMigrationChanged(null);
      assert(!h.state.migrationRunning);
      h.service.running = true; h.state.onMigrationChanged(null);
      assert(h.state.migrationRunning);
    } finally { h.finish('complete'); await work; }
    assert(!h.state.migrationRunning);
  });
  it('keeps retry/unreadable/uncertain results visible and clears busy state on settlement', async () => {
    for (const result of ['retry', 'unreadable', 'uncertain', 'complete', 'cancelled']) {
      const h = harness();
      const work = h.state.migrateOfflineCodes();
      h.finish(result); await work;
      assertEquals(h.state.migrationStatus, ['complete', 'cancelled'].includes(result) ? '' : result);
      assert(!h.state.migrationInFlight); assert(!h.state.migrationRunning);
      assertEquals(h.state.loads, 1);
    }
  });
  it('ignores progress and old promise completion after the Home appearance is superseded', async () => {
    const h = harness();
    const work = h.state.migrateOfflineCodes();
    try {
      h.state.currentGeneration = 2;
      h.state.migrationStatus = 'new appearance';
      h.service.running = true; h.state.onMigrationChanged(null);
      assert(!h.state.migrationRunning);
    } finally { h.finish('retry'); await work; }
    assertEquals(h.state.migrationStatus, 'new appearance');
    assertEquals(h.state.loads, 0);
  });
  it('releases the progress subscription and ignores callbacks when Home disappears', () => {
    const h = harness();
    h.state.aboutToDisappear();
    assert(!h.state.active);
    assert(h.removals.some(([type, fn]) => type === 'migration' && fn === h.state.onMigrationChanged));
    h.service.running = true; h.state.onMigrationChanged(null);
    assert(!h.state.migrationRunning);
  });
});
