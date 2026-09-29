/**
 * framework.mjs — assertion + registration API for the host harness.
 *
 * Kept free of side effects so test modules can import it without creating a
 * cycle with the runner (a cycle plus top-level await deadlocks Node).
 */

const suites = [];
let current = null;

export function describe(name, fn) {
  current = { name, tests: [] };
  suites.push(current);
  fn();
  current = null;
}

export function it(name, fn) {
  if (!current) throw new Error(`it("${name}") called outside describe()`);
  current.tests.push({ name, fn });
}

export function allSuites() {
  return suites;
}

export function assert(cond, msg = 'assertion failed') {
  if (!cond) throw new Error(msg);
}

/** JSON.stringify that survives BigInt and Uint8Array values. */
export function stableStringify(value) {
  return JSON.stringify(value, (_k, v) => {
    if (typeof v === 'bigint') return `${v.toString()}n`;
    if (v instanceof Uint8Array) return `u8[${Array.from(v).map((b) => b.toString(16).padStart(2, '0')).join('')}]`;
    return v;
  });
}

export function assertEquals(actual, expected, msg = '') {
  const a = stableStringify(actual);
  const e = stableStringify(expected);
  if (a !== e) throw new Error(`${msg}\n  expected: ${e}\n  actual:   ${a}`);
}

export function assertBytes(actual, expected, msg = '') {
  const a = actual instanceof Uint8Array ? actual : Uint8Array.from(actual);
  const e = expected instanceof Uint8Array ? expected : Uint8Array.from(expected);
  if (a.length !== e.length) {
    throw new Error(`${msg}\n  length mismatch: expected ${e.length}, actual ${a.length}`);
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== e[i]) {
      throw new Error(
        `${msg}\n  byte ${i}: expected 0x${e[i].toString(16).padStart(2, '0')}, ` +
        `actual 0x${a[i].toString(16).padStart(2, '0')}`);
    }
  }
}

export function assertThrows(fn, msg = 'expected throw') {
  let threw = false;
  try {
    fn();
  } catch (e) {
    threw = true;
  }
  if (!threw) throw new Error(msg);
}

export async function assertRejects(fn, msg = 'expected reject') {
  let threw = false;
  try {
    await fn();
  } catch (e) {
    threw = true;
  }
  if (!threw) throw new Error(msg);
}

export function hex(u8) {
  return Array.from(u8).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function fromHex(s) {
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
  return out;
}

export function fromBase64(s) {
  return new Uint8Array(Buffer.from(s, 'base64'));
}

export function toBase64(u8) {
  return Buffer.from(u8).toString('base64');
}

/** Big-endian bytes -> BigInt. */
export function bytesToBigInt(u8) {
  let v = 0n;
  for (const b of u8) v = (v << 8n) | BigInt(b);
  return v;
}

/** BigInt -> big-endian bytes of exactly `len` bytes (zero padded). */
export function bigIntToBytes(v, len) {
  const out = new Uint8Array(len);
  let x = v;
  for (let i = len - 1; i >= 0; i--) {
    out[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return out;
}
