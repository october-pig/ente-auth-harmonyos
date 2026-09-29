/**
 * kit-arkts.mjs — host shim for `@kit.ArkTS` (the `util` namespace).
 *
 * Implements the documented HarmonyOS behaviour of:
 *   util.Base64Helper.encodeToStringSync(src, options?)
 *   util.Base64Helper.decodeSync(src, options?)
 *   util.Base64Helper.encodeSync(src, options?)
 *   util.TextEncoder / util.TextDecoder
 *
 * `util.Type` (as documented for @ohos.util):
 *   BASIC = 0, MIME = 1, BASIC_URL_SAFE = 2, MIME_URL_SAFE = 3
 * BASIC encodes standard base64 WITH '=' padding; BASIC_URL_SAFE uses the
 * '-'/'_' alphabet and ALSO keeps '=' padding.
 *
 * Deviations from the device are deliberate and conservative: invalid input
 * throws, exactly as the platform documents, so a passing host test cannot be
 * an artefact of a permissive shim.
 */

export const Type = Object.freeze({
  BASIC: 0,
  MIME: 1,
  BASIC_URL_SAFE: 2,
  MIME_URL_SAFE: 3,
});

const STD_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const URL_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

function bytesToBase64(bytes, urlSafe) {
  const alphabet = urlSafe ? URL_ALPHABET : STD_ALPHABET;
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : undefined;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : undefined;
    out += alphabet[b0 >> 2];
    out += alphabet[((b0 & 0x03) << 4) | (b1 === undefined ? 0 : b1 >> 4)];
    out += b1 === undefined ? '=' : alphabet[((b1 & 0x0f) << 2) | (b2 === undefined ? 0 : b2 >> 6)];
    out += b2 === undefined ? '=' : alphabet[b2 & 0x3f];
  }
  return out;
}

function base64ToBytes(str, urlSafe) {
  if (typeof str !== 'string') {
    throw new Error('BusinessError: The input must be a string');
  }
  if (str.length === 0) return new Uint8Array(0);
  if (str.length % 4 !== 0) {
    throw new Error('BusinessError: The input is not a valid base64 string (length % 4 !== 0)');
  }
  const alphabet = urlSafe ? URL_ALPHABET : STD_ALPHABET;
  const reverse = new Map();
  for (let i = 0; i < 64; i++) reverse.set(alphabet[i], i);
  // Strict: reject the other alphabet's punctuation when a specific variant is requested.
  const out = [];
  for (let i = 0; i < str.length; i += 4) {
    const chunk = str.slice(i, i + 4);
    const pad = chunk.endsWith('==') ? 2 : chunk.endsWith('=') ? 1 : 0;
    if (chunk.slice(0, 4 - pad).includes('=')) {
      throw new Error('BusinessError: The input is not a valid base64 string (padding)');
    }
    const vals = [];
    for (let j = 0; j < 4 - pad; j++) {
      const v = reverse.get(chunk[j]);
      if (v === undefined) {
        throw new Error(`BusinessError: The input is not a valid base64 string (char "${chunk[j]}")`);
      }
      vals.push(v);
    }
    out.push(((vals[0] << 2) | (vals[1] >> 4)) & 0xff);
    if (vals.length > 2) out.push(((vals[1] << 4) | (vals[2] >> 2)) & 0xff);
    if (vals.length > 3) out.push(((vals[2] << 6) | vals[3]) & 0xff);
    if (pad && i + 4 !== str.length) {
      throw new Error('BusinessError: The input is not a valid base64 string (padding not at end)');
    }
  }
  return Uint8Array.from(out);
}

export class Base64Helper {
  constructor() {}

  encodeToStringSync(src, options = Type.BASIC) {
    const bytes = src instanceof Uint8Array ? src : Uint8Array.from(src);
    return bytesToBase64(bytes, options === Type.BASIC_URL_SAFE || options === Type.MIME_URL_SAFE);
  }

  encodeSync(src, options = Type.BASIC) {
    const s = this.encodeToStringSync(src, options);
    return new TextEncoder().encode(s);
  }

  async encodeToString(src, options = Type.BASIC) {
    return this.encodeToStringSync(src, options);
  }

  async encode(src, options = Type.BASIC) {
    return this.encodeSync(src, options);
  }

  decodeSync(src, options = Type.BASIC) {
    const urlSafe = options === Type.BASIC_URL_SAFE || options === Type.MIME_URL_SAFE;
    if (src instanceof Uint8Array) {
      return base64ToBytes(new TextDecoder().decode(src), urlSafe);
    }
    return base64ToBytes(src, urlSafe);
  }

  async decode(src, options = Type.BASIC) {
    return this.decodeSync(src, options);
  }
}

/** HarmonyOS ArkTS TextEncoder exposes `encodeInto(string): Uint8Array`. */
export class TextEncoder {
  encodeInto(input) {
    if (typeof input !== 'string') {
      throw new Error('BusinessError: The input must be a string');
    }
    return new globalThis.TextEncoder().encode(input);
  }

  /** Some SDK levels also expose encode(); keep it for completeness. */
  encode(input) {
    return this.encodeInto(input);
  }

  get encoding() {
    return 'utf-8';
  }
}

export class TextDecoder {
  constructor(encoding = 'utf-8') {
    this._d = new globalThis.TextDecoder(encoding, { fatal: true });
  }

  decodeToString(input) {
    return this._d.decode(input);
  }

  decode(input) {
    return this._d.decode(input);
  }

  decodeWithStream(input, options = {}) {
    return this._d.decode(input, { stream: !!options.stream });
  }
}

export const util = {
  Base64Helper,
  TextEncoder,
  TextDecoder,
  Type,
};

export default util;
