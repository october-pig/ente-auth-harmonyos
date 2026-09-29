/** Host shim for `@kit.ScanKit` — device-only (camera / barcode rendering). */
function deviceOnly(name) {
  return () => {
    throw new Error(`DEVICE_ONLY: ${name} is not available in the host harness`);
  };
}
export const scanBarcode = {
  startScanForResult: deviceOnly('scanBarcode.startScanForResult'),
};
export const scanCore = {
  generateBarcode: deviceOnly('scanCore.generateBarcode'),
  ScanType: { QR_CODE: 0, AZTEC: 1, DATA_MATRIX: 2, PDF417: 3, CODE128: 4, EAN13: 5 },
};
/** `generateBarcode` is a ScanKit namespace (see hms/ets/kits/@kit.ScanKit.d.ts). */
export const generateBarcode = {
  createBarcode: deviceOnly('generateBarcode.createBarcode'),
  ErrorCorrectionLevel: { LEVEL_L: 0, LEVEL_M: 1, LEVEL_Q: 2, LEVEL_H: 3 },
};
export default { scanBarcode, scanCore, generateBarcode };
