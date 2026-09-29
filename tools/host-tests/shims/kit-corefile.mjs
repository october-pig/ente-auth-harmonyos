/** Host shim for `@kit.CoreFileKit` — file/picker APIs are device-only. */
function deviceOnly(name) {
  return () => {
    throw new Error(`DEVICE_ONLY: ${name} is not available in the host harness`);
  };
}
export const picker = {
  DocumentViewPicker: class {
    select = deviceOnly('DocumentViewPicker.select');
    save = deviceOnly('DocumentViewPicker.save');
  },
};
export const fileIo = {
  openSync: deviceOnly('fileIo.openSync'),
  readSync: deviceOnly('fileIo.readSync'),
  writeSync: deviceOnly('fileIo.writeSync'),
  closeSync: deviceOnly('fileIo.closeSync'),
  statSync: deviceOnly('fileIo.statSync'),
};
export class BackupExtensionAbility {}
export class BundleVersion {}
export default { picker, fileIo, BackupExtensionAbility, BundleVersion };
