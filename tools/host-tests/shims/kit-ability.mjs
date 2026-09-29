/** Host shim for `@kit.AbilityKit` — only what the port touches. */
export const common = {
  UIAbilityContext: class {},
  Context: class {},
};
export class UIAbility {
  constructor() {}
}
export const AbilityConstant = { LaunchReason: {}, OnContinueResult: {} };
export class Want {
  constructor() {}
}
export default { common, UIAbility, AbilityConstant, Want };
