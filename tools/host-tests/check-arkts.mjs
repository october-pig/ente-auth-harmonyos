/**
 * check-arkts.mjs — syntax + import-resolution check over ALL ArkTS sources,
 * including `entry/src/test/**`.
 *
 * WHY THIS EXISTS
 * ---------------
 * `hvigorw UnitTestBuild` does NOT compile `entry/src/test/**` — it only builds
 * `entry/src/main` and wires up the unit-test hook. The first pass therefore
 * shipped `entry/src/test/FixturesData.ets` containing raw multi-line JSON
 * inside a double-quoted string literal, which is not valid ArkTS, while
 * reporting "3 test suites compile". This check closes that hole.
 *
 * It uses the locked TypeScript dependency (matching the verified parser version) to PARSE every
 * `.ets` file (reporting syntax diagnostics) and to verify that every relative
 * import resolves to a file that exists. It is deliberately NOT a substitute
 * for the ArkTS compiler's type checking — see docs/TESTING.md.
 *
 * Run:  node check-arkts.mjs
 */
import { createRequire } from 'node:module';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
let ts;
try {
  ts = require('typescript');
} catch {
  console.error('[check-arkts] Missing compiler. Run npm ci in tools/host-tests.');
  process.exit(1);
}

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..');
const ROOTS = ['entry/src/main/ets', 'entry/src/test', 'entry/src/ohosTest'];

function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (full.endsWith('.ets')) out.push(full);
  }
  return out;
}

const IMPORT_RE = /^\s*(?:import|export)\s[^;]*?from\s+['"]([^'"]+)['"]/gm;
const BARE_IMPORT_RE = /^\s*import\s+['"]([^'"]+)['"]/gm;

/**
 * ArkUI declarative syntax (`@Component struct X { build() { Column() { ... } } }`)
 * is not TypeScript and cannot be parsed by the TS compiler. Those files ARE
 * compiled by the ArkTS compiler during `assembleHap`, so they are already
 * covered. The hole this check fills is `entry/src/test/**`, which the main
 * build never compiles.
 */
function usesArkUI(src) {
  return /^\s*(?:@\w+\s*)*struct\s+\w+/m.test(src) ||
    /@(Component|Entry|Builder|Extend|Styles|CustomDialog|Preview|Reusable|AnimatableExtend|LocalBuilder)\b/.test(src) ||
    /^\s*build\s*\(\s*\)\s*\{/m.test(src);
}

let files = 0;
let skippedArkUI = 0;
let syntaxErrors = 0;
let unresolved = 0;
const problems = [];

for (const root of ROOTS) {
  for (const file of walk(join(REPO, root))) {
    const rel = relative(REPO, file).replace(/\\/g, '/');
    const src = readFileSync(file, 'utf8');
    if (usesArkUI(src)) {
      skippedArkUI++;
      continue;
    }
    files++;

    const out = ts.transpileModule(src, {
      reportDiagnostics: true,
      fileName: file,
      compilerOptions: {
        target: ts.ScriptTarget.ES2021,
        module: ts.ModuleKind.ESNext,
        experimentalDecorators: true,
      },
    });
    for (const d of out.diagnostics ?? []) {
      if (d.category !== ts.DiagnosticCategory.Error) continue;
      syntaxErrors++;
      const pos = d.file && d.start !== undefined
        ? d.file.getLineAndCharacterOfPosition(d.start)
        : null;
      problems.push(`${rel}${pos ? `:${pos.line + 1}:${pos.character + 1}` : ''}: ` +
        `${ts.flattenDiagnosticMessageText(d.messageText, ' ')}`);
    }

    // Relative import resolution
    for (const re of [IMPORT_RE, BARE_IMPORT_RE]) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(src)) !== null) {
        const spec = m[1];
        if (!spec.startsWith('.')) continue;
        const base = resolve(dirname(file), spec);
        const candidates = [
          base, `${base}.ets`, `${base}.ts`, `${base}.d.ts`,
          join(base, 'index.ets'), join(base, 'index.ts'),
        ];
        if (!candidates.some((c) => existsSync(c))) {
          unresolved++;
          problems.push(`${rel}: unresolved relative import "${spec}"`);
        }
      }
    }
  }
}

console.log(`[check-arkts] parsed ${files} .ets files; ` +
  `${skippedArkUI} ArkUI files skipped (covered by assembleHap's ArkTS compile)`);
for (const p of problems) console.log(`  PROBLEM  ${p}`);
console.log(`ARKTS_CHECK_SUMMARY ${JSON.stringify({ files, skippedArkUI, syntaxErrors, unresolved, problems })}`);
process.exitCode = problems.length === 0 ? 0 : 1;
