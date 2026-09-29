/**
 * hooks.mjs — Node module-resolution hook that lets the real ArkTS sources run
 * on the host.
 *
 * Two jobs:
 *  1. Map HarmonyOS `@kit.*` / `@ohos.*` module specifiers and the
 *     `libentecrypto.so` NAPI module onto host shims.
 *  2. Resolve ArkTS-style extensionless relative imports (`./Base32`) the way
 *     the ArkTS compiler does (append `.ts`, then `/index.ts`).
 *
 * It deliberately does NOT rewrite any source text.
 */
import { existsSync } from 'node:fs';
import { dirname, join, resolve as presolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SHIMS = join(HERE, 'shims');

/** HarmonyOS kit module -> host shim. */
const KIT_MAP = {
  '@kit.ArkTS': 'kit-arkts.mjs',
  '@kit.CryptoArchitectureKit': 'kit-crypto.mjs',
  '@kit.ArkData': 'kit-arkdata.mjs',
  '@kit.NetworkKit': 'kit-network.mjs',
  '@kit.BasicServicesKit': 'kit-basic.mjs',
  '@kit.PerformanceAnalysisKit': 'kit-perf.mjs',
  '@kit.AbilityKit': 'kit-ability.mjs',
  '@kit.ArkUI': 'kit-arkui.mjs',
  '@kit.CoreFileKit': 'kit-corefile.mjs',
  '@kit.ImageKit': 'kit-image.mjs',
  '@kit.ScanKit': 'kit-scan.mjs',
  '@kit.UniversalKeystoreKit': 'kit-huks.mjs',
  '@kit.LocalizationKit': 'kit-localization.mjs',
  'libentecrypto.so': 'entecrypto.mjs',
};

/** Shims that exist but intentionally throw when used (device-only capability). */
export const DEVICE_ONLY = new Set([
  '@kit.UniversalKeystoreKit',
  '@kit.ScanKit',
  '@kit.ImageKit',
]);

function tryFile(p) {
  const candidates = [p, `${p}.ts`, `${p}.mjs`, `${p}.js`, join(p, 'index.ts'), join(p, 'index.mjs')];
  // ArkTS sources may import each other with an EXPLICIT `.ets` extension
  // (`import { X } from './PageParams.ets'`). `prepare.mjs` materialises those as
  // `.ts`, so an explicit `.ets` specifier must be mapped across, exactly as the
  // ArkTS compiler does. Without this, any production module that uses the
  // explicit form is unloadable on the host — which silently excludes it from
  // host testing.
  if (p.endsWith('.ets')) {
    candidates.push(`${p.slice(0, -'.ets'.length)}.ts`);
  }
  for (const cand of candidates) {
    if (existsSync(cand)) return cand;
  }
  return null;
}

export async function resolve(specifier, context, nextResolve) {
  // 1. HarmonyOS kit modules / native module
  if (Object.prototype.hasOwnProperty.call(KIT_MAP, specifier)) {
    const shim = join(SHIMS, KIT_MAP[specifier]);
    return { url: pathToFileURL(shim).href, shortCircuit: true };
  }
  // Any other @kit.* / @ohos.* that we have not shimmed is a hard error rather
  // than a silent skip: a test must never pass because a platform call vanished.
  if (specifier.startsWith('@kit.') || specifier.startsWith('@ohos.') ||
      specifier.startsWith('@hms.') || specifier.endsWith('.so')) {
    throw new Error(
      `[hooks] No host shim for platform module "${specifier}". ` +
      `Add one under tools/host-tests/shims/ or exclude the importing module from host tests.`);
  }

  // 2. Extensionless relative imports (ArkTS style)
  if (specifier.startsWith('.') || specifier.startsWith('/')) {
    const parent = context.parentURL ? fileURLToPath(context.parentURL) : join(HERE, 'x.ts');
    const base = specifier.startsWith('/')
      ? specifier
      : presolve(dirname(parent), specifier);
    const hit = tryFile(base);
    if (hit) return { url: pathToFileURL(hit).href, shortCircuit: true };
  }

  return nextResolve(specifier, context);
}
