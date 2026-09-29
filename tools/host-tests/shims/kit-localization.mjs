/**
 * kit-localization.mjs — host shim for `@kit.LocalizationKit`.
 *
 * TEST MODEL ASSUMPTION. The host harness has no HarmonyOS resource system, so
 * `S.init()` is never called and `AppStrings` accessors deliberately fall back to
 * returning their own resource KEY. That is what the localization guards assert
 * against: they check that the key sets in the Chinese and English resource files
 * are identical and that no user-visible string is hardcoded in a component.
 *
 * This shim therefore exposes only what `AppStrings.ets` needs to COMPILE and
 * LOAD — the `resourceManager` namespace for its type annotation. It does not,
 * and cannot, model real resource resolution: actual localized output is
 * DEVICE-verified only (see docs/TESTING.md).
 */

/** Placeholder namespace: `resourceManager.ResourceManager` is only a type here. */
export const resourceManager = Object.freeze({});

export default { resourceManager };
