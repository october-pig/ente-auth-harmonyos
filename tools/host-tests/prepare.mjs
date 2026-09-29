/**
 * prepare.mjs — materialise the REAL ArkTS production sources as Node-loadable
 * TypeScript, WITHOUT modifying them.
 *
 * Why: Node 24 can execute TypeScript directly (type stripping), but only for
 * `.ts`/`.mts`/`.cts` extensions. ArkTS uses `.ets`. This script copies each
 * production `.ets` file byte-for-byte to `gen/<same path>.ts` and records the
 * SHA-256 of the source so the test run can prove it executed production code.
 *
 * Nothing here changes behaviour: it is a pure copy.
 */
import { createHash } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..');
const GEN = join(HERE, 'gen');

const SOURCE_ROOTS = ['entry/src/main/ets'];

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (full.endsWith('.ets')) out.push(full);
  }
  return out;
}

rmSync(GEN, { recursive: true, force: true });

const manifest = [];
for (const root of SOURCE_ROOTS) {
  const abs = join(REPO, root);
  for (const src of walk(abs)) {
    const rel = relative(REPO, src).replace(/\\/g, '/');
    const destRel = rel.replace(/\.ets$/, '.ts');
    const dest = join(GEN, destRel);
    const bytes = readFileSync(src);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, bytes);
    manifest.push({
      source: rel,
      generated: `gen/${destRel}`,
      sha256: createHash('sha256').update(bytes).digest('hex'),
      bytes: bytes.length,
    });
  }
}

writeFileSync(join(GEN, 'MANIFEST.json'), JSON.stringify({
  generatedAt: new Date().toISOString(),
  note: 'Byte-for-byte copies of production ArkTS sources. Verify sha256 against the repo.',
  files: manifest,
}, null, 2));

console.log(`[prepare] ${manifest.length} production .ets files copied to gen/ (byte-identical)`);
