/**
 * run.mjs — deterministic test runner for the host harness.
 *
 * Canonical invocation (see tools/host-tests/run.ps1):
 *   node --experimental-transform-types --no-warnings --import ./register.mjs run.mjs
 *
 * Prints a machine-readable HOSTTEST_SUMMARY line with real counts.
 */
import { readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { allSuites } from './framework.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TESTS = join(HERE, 'tests');

const files = readdirSync(TESTS).filter((f) => f.endsWith('.test.mjs')).sort();
for (const f of files) {
  await import(pathToFileURL(join(TESTS, f)).href);
}

let pass = 0;
let fail = 0;
const failures = [];
for (const s of allSuites()) {
  console.log(`\n=== ${s.name} ===`);
  for (const t of s.tests) {
    try {
      await t.fn();
      pass++;
      console.log(`  PASS  ${t.name}`);
    } catch (e) {
      fail++;
      console.log(`  FAIL  ${t.name}`);
      console.log(`        ${String(e.message).split('\n').join('\n        ')}`);
      failures.push({ suite: s.name, test: t.name, error: String(e.message) });
    }
  }
}

console.log(`\nHOSTTEST_SUMMARY ${JSON.stringify({
  suites: allSuites().length,
  files: files.length,
  pass,
  fail,
  failures,
})}`);
process.exitCode = fail === 0 ? 0 : 1;
