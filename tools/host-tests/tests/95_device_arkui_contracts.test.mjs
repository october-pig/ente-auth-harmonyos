/**
 * 95_device_arkui_contracts.test.mjs — guards for defects found ONLY on a device.
 *
 * Every case here is a STRUCTURAL CHECK over ArkUI `@Component` sources that the
 * host harness cannot execute. They encode framework contracts that a compiler,
 * a linter and a source-reading agent all accepted silently, and that were only
 * visible on a real device (HUAWEI Mate 80 Pro Max, SGT-AL10, API 26,
 * HarmonyOS 7.0.0.105):
 *
 *   1. `get` accessors on a `@Component struct` do not exist at runtime.
 *   2. only ONE `bindSheet` per component renders; the rest are suppressed.
 *   3. a plain (undecorated) member of a child `@Component` never updates.
 *   4. `navDestination` must resolve to a `NavDestination` node.
 *
 * These are NOT device verification. They prove the source keeps the shape the
 * device required; the device evidence is recorded in docs/TESTING.md
 * (round 3). Actual rendering remains DEVICE-gated.
 */
import { assert, assertEquals, describe, it } from '../framework.mjs';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..', '..');
const ETS = join(REPO, 'entry/src/main/ets');

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (full.endsWith('.ets')) out.push(full);
  }
  return out;
}

const sources = walk(ETS).map((p) => ({
  rel: p.slice(REPO.length + 1).replace(/\\/g, '/'),
  src: readFileSync(p, 'utf8'),
}));

/** Every `@Component`/`struct` body in a file, by brace matching. */
function structBodies(src) {
  const out = [];
  const re = /(?:@\w+[^\n]*\n)*\s*struct\s+(\w+)\s*\{/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const open = src.indexOf('{', m.index + m[0].length - 1);
    let depth = 0;
    for (let i = open; i < src.length; i++) {
      if (src[i] === '{') depth++;
      else if (src[i] === '}') {
        depth--;
        if (depth === 0) {
          out.push({ name: m[1], body: src.slice(open, i + 1) });
          break;
        }
      }
    }
  }
  return out;
}

describe('device-found ArkUI contract: no getters on @Component structs', () => {
  it('STRUCTURAL CHECK — no struct declares a get accessor', () => {
    const offenders = [];
    for (const f of sources) {
      for (const s of structBodies(f.src)) {
        // NOTE: the modifier is optional but must be matched. The first version
        // of this guard required the line to START with `get`, so `private get
        // codeText()` in CodeCard.ets slipped through and the resulting
        // `Cannot read property length of undefined` crashed the app on every
        // cold start once a real account had codes (see docs/TESTING.md,
        // real-account post-login crash).
        if (/^\s*(?:private|public|protected|static|readonly)?\s*get\s+\w+\s*\(/m.test(s.body)) {
          offenders.push(`${f.rel}:${s.name}`);
        }
      }
    }
    assertEquals(offenders, [],
      'ArkUI does not compile get accessors on a struct - they return undefined '
      + 'at runtime, and a build-time TypeError is FATAL (device-verified crash). '
      + 'Use a method instead.');
  });

  it('STRUCTURAL CHECK — every struct accessor-shaped member is called', () => {
    // Belt and braces: if an accessor ever returns, the call sites must use ().
    const offenders = [];
    for (const f of sources) {
      for (const s of structBodies(f.src)) {
        const names = [...s.body.matchAll(/^\s*(?:private|public|protected)?\s*get\s+(\w+)\s*\(/gm)]
          .map((m) => m[1]);
        for (const n of names) {
          const re = new RegExp(`this\\.${n}\\b(?!\\s*\\()`);
          if (re.test(s.body)) offenders.push(`${f.rel}:${s.name}.${n}`);
        }
      }
    }
    assertEquals(offenders, []);
  });

  it('plain classes may still use getters (Code, CodeDisplay)', () => {
    // The rule is about `@Component struct`, not about ArkTS classes: `Code` and
    // `CodeDisplay` getters work and are used throughout.
    const code = sources.find((f) => f.rel.endsWith('models/Code.ets'));
    assert(code !== undefined, 'Code.ets present');
    assert(/^\s+get\s+isTrashed\s*\(/m.test(code.src), 'Code keeps its class getters');
  });
});

describe('device-found ArkUI contract: one bindSheet per component', () => {
  it('STRUCTURAL CHECK — at most one bindSheet per component', () => {
    const offenders = [];
    for (const f of sources) {
      for (const s of structBodies(f.src)) {
        const n = (s.body.match(/\.bindSheet\(/g) ?? []).length;
        if (n > 1) offenders.push(`${f.rel}:${s.name} has ${n}`);
      }
    }
    assertEquals(offenders, [],
      'ArkUI renders only ONE bindSheet per component; attaching several '
      + 'suppresses all of them (device-verified). Switch the sheet CONTENT by '
      + 'state instead — see SheetKind in HomePage.ets.');
  });

  it('HomePage routes every sheet trigger through the single host', () => {
    const home = sources.find((f) => f.rel.endsWith('pages/HomePage.ets'));
    assert(home !== undefined, 'HomePage.ets present');
    assertEquals((home.src.match(/\.bindSheet\(/g) ?? []).length, 1,
      'exactly one bindSheet host');
    assert(home.src.includes('openSheet(SheetKind.'), 'triggers use openSheet');
    assert(home.src.includes('buildActiveSheet'), 'content is switched by state');
  });
});

describe('device-found ArkUI contract: child members need @Prop to update', () => {
  it('STRUCTURAL CHECK — dynamic child members are decorated', () => {
    // Members that a parent drives from state must be @Prop/@Link/@ObjectLink.
    // Only `selected`/`label`/`checked`-style display members are checked; plain
    // callbacks are initialised once and that is fine.
    const offenders = [];
    for (const f of sources) {
      for (const s of structBodies(f.src)) {
        // A member named `selected` or `checked` without a decorator is the
        // exact shape that broke the All/Trash chips.
        const bad = /^\s{2}(selected|checked)\s*:\s*boolean/m.test(s.body);
        if (bad) offenders.push(`${f.rel}:${s.name}`);
      }
    }
    assertEquals(offenders, [],
      'a plain member of a child @Component is initialised once and never '
      + 'updates (device-verified: the All/Trash selection never moved). '
      + 'Decorate it with @Prop.');
  });
});

describe('device-found ArkUI contract: navDestination needs a NavDestination', () => {
  it('STRUCTURAL CHECK — PageMap wraps its content in HdsNavDestination', () => {
    const index = sources.find((f) => f.rel.endsWith('pages/Index.ets'));
    assert(index !== undefined, 'Index.ets present');
    const pm = /@Builder\s+PageMap\(name: string\)\s*\{([\s\S]*?)\n  \}/.exec(index.src);
    assert(pm !== null, 'PageMap builder found');
    const body = pm[1];
    assert(body.includes('HdsNavDestination()'),
      'navDestination must resolve to a NavDestination node, otherwise ArkUI '
      + 'renders a default shell with NO content (device-verified: every pushed '
      + 'route was blank; router error 100006 "NavDestination not found").');
    assert(body.indexOf('HdsNavDestination()') < body.indexOf('if (name ==='),
      'the NavDestination is the root the branches live inside');
  });
});
