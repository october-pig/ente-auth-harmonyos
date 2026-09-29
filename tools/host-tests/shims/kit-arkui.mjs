/** Host shim for `@kit.ArkUI` — UI-only; the harness never exercises UI. */
function deviceOnly(name) {
  return () => {
    throw new Error(`DEVICE_ONLY: ${name} is not available in the host harness`);
  };
}
export const promptAction = {
  showToast: deviceOnly('promptAction.showToast'),
  showDialog: deviceOnly('promptAction.showDialog'),
  openCustomDialog: deviceOnly('promptAction.openCustomDialog'),
};
export const window = {
  getLastWindow: deviceOnly('window.getLastWindow'),
};
export default { promptAction, window };
