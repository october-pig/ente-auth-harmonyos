/** Host shim for `@kit.ImageKit` — device-only. */
function deviceOnly(name) {
  return () => {
    throw new Error(`DEVICE_ONLY: ${name} is not available in the host harness`);
  };
}
export const image = {
  createImagePacker: deviceOnly('image.createImagePacker'),
  createImageSource: deviceOnly('image.createImageSource'),
};
export default { image };
