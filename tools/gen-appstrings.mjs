/**
 * gen-appstrings.mjs — generate AppStrings.ets from the Chinese resource file.
 *
 * WHY: AppStrings.ets is a thin accessor layer over the HarmonyOS resource
 * system. Generating it from `base/element/app_strings.json` guarantees that
 * every accessor has a backing resource key, so the two cannot drift.
 *
 * Run:  node tools/gen-appstrings.mjs
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');
const BASE = join(REPO, 'entry/src/main/resources/base/element/app_strings.json');
const OUT = join(REPO, 'entry/src/main/ets/app/AppStrings.ets');

const base = JSON.parse(readFileSync(BASE, 'utf8'));
const keys = base.string.map((s) => s.name);

const lines = [];
lines.push('/**');
lines.push(' * UI string accessor - a THIN layer over the HarmonyOS resource system.');
lines.push(' *');
lines.push(' * GENERATED FILE - do not edit by hand. Run `node tools/gen-appstrings.mjs`.');
lines.push(' *');
lines.push(' * Source of truth for every user-visible string:');
lines.push(' *   entry/src/main/resources/base/element/app_strings.json    (Chinese, DEFAULT)');
lines.push(' *   entry/src/main/resources/en_US/element/app_strings.json   (English)');
lines.push(' *');
lines.push(' * `base` is Chinese, so an unmatched locale falls back to Chinese; `en_US`');
lines.push(' * supplies English. Brand and technical terms (Ente, TOTP, HOTP, QR, GitHub,');
lines.push(' * URL, API) are deliberately identical in both files.');
lines.push(' *');
lines.push(' * Resolution is by NAME (`getStringByNameSync`) rather than by `$r(...)` id so');
lines.push(' * that this module stays loadable by the host test harness, which has no ArkUI');
lines.push(' * runtime. Before `init()` - i.e. on the host, or before the ability starts -');
lines.push(' * every accessor returns its own key, which is exactly what the localization');
lines.push(' * guards assert against.');
lines.push(' */');
lines.push("import { resourceManager } from '@kit.LocalizationKit';");
lines.push('');
lines.push('let mgr: resourceManager.ResourceManager | undefined = undefined;');
lines.push('');
lines.push('export class S {');
lines.push('  /** Called once from EntryAbility with the ability context. */');
lines.push('  static init(m: resourceManager.ResourceManager): void {');
lines.push('    mgr = m;');
lines.push('  }');
lines.push('');
lines.push('  /** True once the resource manager is available (false on the host). */');
lines.push('  static isReady(): boolean {');
lines.push('    return mgr !== undefined;');
lines.push('  }');
lines.push('');
lines.push('  /**');
lines.push('   * Resolve a key. Falls back to the key itself when the resource manager is');
lines.push('   * unavailable or the key is missing, so a bad key degrades to a visible');
lines.push('   * identifier instead of crashing the UI.');
lines.push('   */');
lines.push('  private static r(key: string, args?: Array<string | number>): string {');
lines.push('    if (mgr === undefined) {');
lines.push('      return key;');
lines.push('    }');
lines.push('    try {');
lines.push('      return args === undefined');
lines.push('        ? mgr.getStringByNameSync(key)');
lines.push('        : mgr.getStringByNameSync(key, args[0]);');
lines.push('    } catch (e) {');
lines.push('      return key;');
lines.push('    }');
lines.push('  }');
lines.push('');

for (const s of base.string) {
  const v = String(s.value);
  const m = /%1\$([dsf])/.exec(v);
  if (m) {
    const type = m[1] === 'd' || m[1] === 'f' ? 'number' : 'string';
    lines.push(`  static ${s.name}(arg: ${type}): string {`);
    lines.push(`    return S.r('${s.name}', [arg]);`);
    lines.push('  }');
  } else {
    lines.push(`  static ${s.name}(): string {`);
    lines.push(`    return S.r('${s.name}');`);
    lines.push('  }');
  }
}
lines.push('}');
lines.push('');

writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log(`[gen-appstrings] wrote ${keys.length} accessors to entry/src/main/ets/app/AppStrings.ets`);
