/**
 * 97_localization_guards.test.mjs — guards for the Chinese-first localization.
 *
 * WHAT THIS PROVES, AND WHAT IT DOES NOT
 * --------------------------------------
 * These are STATIC checks over the resource files and the ArkTS sources. They
 * prove that:
 *   - the Chinese and English resource files define exactly the same key set;
 *   - every accessor in the generated `AppStrings.ets` has a backing key;
 *   - no component hardcodes user-visible English text;
 *   - no accessor is referenced without being called.
 *
 * They do NOT prove that the device renders Chinese. The host harness has no
 * resource system (`S.init()` is never called, so accessors return their own
 * key). Actual localized output is DEVICE-verified only.
 */
import { assert, assertEquals, describe, it } from '../framework.mjs';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..', '..', '..');
const ETS = join(REPO, 'entry/src/main/ets');
const ZH = join(REPO, 'entry/src/main/resources/base/element/app_strings.json');
const EN = join(REPO, 'entry/src/main/resources/en_US/element/app_strings.json');

function loadStrings(p) {
  const json = JSON.parse(readFileSync(p, 'utf8'));
  const map = new Map();
  for (const s of json.string) map.set(s.name, String(s.value));
  return map;
}

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

const zh = loadStrings(ZH);
const en = loadStrings(EN);

// ------------------------------------------------------------------ key parity

describe('localization — resource key parity', () => {
  it('Chinese and English define the same key set', () => {
    const zk = [...zh.keys()].sort();
    const ek = [...en.keys()].sort();
    const onlyZh = zk.filter((k) => !en.has(k));
    const onlyEn = ek.filter((k) => !zh.has(k));
    assertEquals(onlyZh, [], 'keys missing from en_US (no English fallback)');
    assertEquals(onlyEn, [], 'keys missing from base/Chinese');
    assertEquals(zk.length, ek.length, 'same key count');
  });

  it('no resource value is empty', () => {
    const empty = [];
    for (const [k, v] of zh) if (v.trim() === '') empty.push(`zh:${k}`);
    for (const [k, v] of en) if (v.trim() === '') empty.push(`en:${k}`);
    assertEquals(empty, []);
  });

  it('base is Chinese, not English (Chinese is the DEFAULT language)', () => {
    // A sample of keys that MUST contain Han characters in the base file. If
    // someone "fixes" a string by pasting English into base, this fails.
    const mustBeChinese = ['settings', 'logout', 'login', 'createAccount', 'trash',
      'scanAQrCode', 'recoveryKeyTitle', 'twoFactorAuthentication', 'password', 'save'];
    const bad = [];
    for (const k of mustBeChinese) {
      const v = zh.get(k) ?? '';
      if (!/[\u4e00-\u9fff]/.test(v)) bad.push(`${k} = "${v}"`);
    }
    assertEquals(bad, [], 'these base values are not Chinese');
  });

  it('English values are not Chinese (the two locales are really different)', () => {
    const bad = [];
    for (const [k, v] of en) {
      if (/[\u4e00-\u9fff]/.test(v)) bad.push(`${k} = "${v}"`);
    }
    assertEquals(bad, [], 'en_US must not contain Han characters');
  });

  it('brand and technical terms are untranslated in both locales', () => {
    assertEquals(zh.get('appName'), en.get('appName'), 'appName is locale-invariant');
    assertEquals(zh.get('github'), en.get('github'), 'GitHub is locale-invariant');
    assertEquals(zh.get('appName'), 'ente Auth', 'brand is not translated');
    assertEquals(zh.get('github'), 'GitHub', 'GitHub is not translated');
    // Technical acronyms must survive translation.
    assert(zh.get('notSupportedForHOTP').includes('HOTP'),
      'HOTP must stay literal in Chinese');
    assert(zh.get('enterSixDigitCode').includes('6'),
      'the 6-digit wording is preserved');
    // The desktop label must stay the brand in both locales.
    const zhLabel = JSON.parse(readFileSync(
      join(REPO, 'entry/src/main/resources/base/element/string.json'), 'utf8'));
    const enLabel = JSON.parse(readFileSync(
      join(REPO, 'entry/src/main/resources/en_US/element/string.json'), 'utf8'));
    const find = (j, n) => j.string.find((s) => s.name === n)?.value;
    assertEquals(find(zhLabel, 'EntryAbility_label'), 'Ente Auth', 'app name (zh)');
    assertEquals(find(enLabel, 'EntryAbility_label'), 'Ente Auth', 'app name (en)');
  });

  it('parameterized placeholders are identical in both locales', () => {
    const bad = [];
    for (const [k, v] of zh) {
      const zp = [...v.matchAll(/%\d+\$[dsf]/g)].map((m) => m[0]).sort();
      const ep = [...(en.get(k) ?? '').matchAll(/%\d+\$[dsf]/g)].map((m) => m[0]).sort();
      if (zp.join(',') !== ep.join(',')) bad.push(`${k}: zh=[${zp}] en=[${ep}]`);
    }
    assertEquals(bad, [], 'placeholder sets must match across locales');
  });
});

// ------------------------------------------------------- accessor <-> resource

describe('localization — AppStrings accessor layer', () => {
  const appStrings = sources.find((f) => f.rel.endsWith('app/AppStrings.ets'));
  const accessors = [...appStrings.src.matchAll(/^\s{2}static (\w+)\(/gm)].map((m) => m[1])
    .filter((n) => n !== 'init' && n !== 'isReady' && n !== 'r');

  it('every accessor has a backing resource key', () => {
    const missing = accessors.filter((a) => !zh.has(a));
    assertEquals(missing, [], 'accessors without a resource key');
  });

  it('every resource key has an accessor', () => {
    const missing = [...zh.keys()].filter((k) => !accessors.includes(k));
    assertEquals(missing, [], 'resource keys with no accessor');
  });

  it('accessors resolve by NAME, so the module stays host-loadable', () => {
    assert(appStrings.src.includes('getStringByNameSync'),
      'resolution must be by name (no ArkUI $r, which the host cannot evaluate)');
    // Check for real USAGE, not a mention in the explanatory comment.
    assert(!/\$r\('app\./.test(appStrings.src),
      'AppStrings must not use $r(): Router imports it and the host harness loads it');
  });

  it('a missing resource degrades to the key instead of throwing', () => {
    assert(appStrings.src.includes('return key;'),
      'the resolver must fall back to the key rather than crash the UI');
  });
});

// ------------------------------------------------- hardcoded user-visible text

describe('localization — no hardcoded user-visible text in components', () => {
  /** Symbols and non-text glyphs that are legitimately literal. */
  const GLYPH_OK = new Set(['+', '-', 'x', '\u2190', '\u2715', '\u2261', '\u21c5',
    '\u2713', '\u25bc', '\u25b2', '>', '<', '\u2192']);

  /**
   * BRAND — deliberately NOT translated, in any locale (mission rule).
   * The logo is an "ente" + "Auth" lockup, and the About page shows the app name.
   */
  const BRAND_OK = new Set(['ente', 'Auth', 'ente Auth', 'Ente', 'Ente Auth']);

  function looksLikeUiText(v) {
    const s = v.trim();
    if (s.length < 2) return false;
    if (GLYPH_OK.has(s)) return false;
    if (BRAND_OK.has(s)) return false;
    if (/^#[0-9A-Fa-f]{3,8}$/.test(s)) return false;      // colour
    if (/^[\W\d_]+$/.test(s)) return false;                // punctuation / digits
    if (/^https?:\/\//.test(s)) return false;              // URL
    if (/^[a-z0-9_.\-/]+$/.test(s)) return false;          // identifiers, keys, paths
    return /[A-Za-z]{2,}/.test(s);                         // contains real words
  }

  it('Text()/Button()/placeholder/Toast/dialog literals are localized', () => {
    const offenders = [];
    const re = /(?:Text|Button)\(\s*'([^']*)'|placeholder:\s*'([^']*)'|Toast\.show\(\s*'([^']*)'|title:\s*'([^']*)'|message:\s*'([^']*)'/g;
    for (const f of sources) {
      if (f.rel.endsWith('app/AppStrings.ets')) continue;
      const lines = f.src.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const t = lines[i].trim();
        if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) continue;
        if (t.includes('Logger.') || t.includes('console.')) continue;
        re.lastIndex = 0;
        let m;
        while ((m = re.exec(lines[i])) !== null) {
          const v = m.slice(1).find((g) => g !== undefined);
          if (v !== undefined && looksLikeUiText(v)) {
            offenders.push(`${f.rel}:${i + 1}: "${v}"`);
          }
        }
      }
    }
    assertEquals(offenders, [],
      'user-visible text must come from the resource system (S.<key>())');
  });

  it('template literals containing prose are localized', () => {
    // Scope: files that RENDER UI. Error strings thrown by services, otpauth://
    // protocol strings and the HTML export template are not user-visible UI text
    // (mission rule: HTTP/technical identifiers may stay English).
    const UI_DIRS = ['/pages/', '/components/'];
    const NON_UI = [/throw\b/, /new Error\(/, /otpauth:\/\//, /<p\b/, /<td\b/,
      /<section\b/, /<tr\b/, /<\/tr>/, /UnsupportedError/, /FormatException/];
    const offenders = [];
    for (const f of sources) {
      if (!UI_DIRS.some((d) => f.rel.includes(d))) continue;
      const lines = f.src.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const t = lines[i].trim();
        if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) continue;
        if (NON_UI.some((re) => re.test(lines[i]))) continue;
        for (const m of lines[i].matchAll(/`([^`]*)`/g)) {
          const body = m[1];
          if (!/[A-Za-z]{2,}/.test(body)) continue;
          const stripped = body.replace(/\$\{[^}]*\}/g, '');
          if (looksLikeUiText(stripped)) offenders.push(`${f.rel}:${i + 1}: \`${body}\``);
        }
      }
    }
    assertEquals(offenders, [], 'prose in a template literal must be localized');
  });

  it('no accessor is referenced without being called', () => {
    const offenders = [];
    for (const f of sources) {
      if (f.rel.endsWith('app/AppStrings.ets')) continue;
      const lines = f.src.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const t = lines[i].trim();
        if (t.startsWith('//') || t.startsWith('*')) continue;
        // `\b` after the group prevents the regex from backtracking into a
        // partial name (S.settings() must not report "S.setting").
        const m = /\bS\.(\w+)\b(?!\s*\()/.exec(lines[i]);
        if (m) offenders.push(`${f.rel}:${i + 1}: S.${m[1]} (missing call)`);
      }
    }
    assertEquals(offenders, []);
  });

  it('the removed fmt() helper is gone', () => {
    const appStrings = sources.find((f) => f.rel.endsWith('app/AppStrings.ets'));
    assert(!/export function fmt\(/.test(appStrings.src),
      'fmt() is replaced by parameterized resource accessors');
    const users = sources.filter((f) => /\bfmt\(/.test(f.src) && !f.rel.endsWith('app/AppStrings.ets'));
    assertEquals(users.map((f) => f.rel), [], 'no caller may still use fmt()');
  });
});
