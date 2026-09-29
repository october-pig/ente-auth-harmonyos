/** Host shim for `@kit.BasicServicesKit` — BusinessError only. */
export class BusinessError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}
export const pasteboard = {
  createData: () => {
    throw new Error('DEVICE_ONLY: pasteboard is not available in the host harness');
  },
  getSystemPasteboard: () => {
    throw new Error('DEVICE_ONLY: pasteboard is not available in the host harness');
  },
};
export default { BusinessError, pasteboard };
