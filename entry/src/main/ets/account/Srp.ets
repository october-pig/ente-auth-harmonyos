/**
 * SRP-6a client — byte-compatible port of the pointycastle 3.9.1 SRP6Client /
 * SRP6Util / SRP6VerifierGenerator used by upstream Ente accounts
 * (`packages/accounts/lib/services/user_service.dart`):
 *   group rfc5054_4096 (g=5), digest SHA-256;
 *   x = H(salt || H(identity || ':' || password));
 *   a = random in [2^255, N-1]; A = g^a mod N;
 *   k = H(pad(N) || pad(g));  u = H(pad(A) || pad(B));
 *   S = (B - k*g^x mod N) ^ (a + u*x) mod N;
 *   M1 = H(pad(A) || pad(B) || pad(S)).
 * All pads are to 512 bytes. SHA-256 from Crypto Architecture Kit.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * RFC 5054 Appendix A, 4096-bit group modulus — verbatim from upstream
 * `pointycastle 3.9.1` `SRP6StandardGroups.rfc5054_4096_N`
 * (`.upstream/pub/lib/srp/srp6_standard_groups.dart:70-89`), which is what
 * `kDefaultSrpGroup` selects
 * (`.upstream/ente/mobile/packages/accounts/lib/services/user_service.dart:55`).
 *
 * Split across lines exactly like the upstream source so the two can be
 * diffed by eye. 1024 hex characters = 4096 bits.
 */
const RFC5054_4096_N_HEX: string =
  'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08' +
  '8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B' +
  '302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9' +
  'A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6' +
  '49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8' +
  'FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D' +
  '670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C' +
  '180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718' +
  '3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D' +
  '04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7D' +
  'B3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D226' +
  '1AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C' +
  'BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFC' +
  'E0FD108E4B82D120A92108011A723C12A787E6D788719A10BDBA5B26' +
  '99C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB' +
  '04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2' +
  '233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127' +
  'D5B05AA993B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199' +
  'FFFFFFFFFFFFFFFF';

/** (N.bitLength + 7) ~/ 8 for the 4096-bit group == 512. */
const PAD_LENGTH: number = 512;

export class Srp {
  static readonly N: bigint = BigInt('0x' + RFC5054_4096_N_HEX);
  static readonly g: bigint = BigInt(5);

  /** Modular exponentiation (square & multiply). */
  static modPow(base: bigint, exp: bigint, mod: bigint): bigint {
    let result: bigint = BigInt(1);
    let b: bigint = base % mod;
    if (b < BigInt(0)) {
      b = b + mod;
    }
    let e: bigint = exp;
    while (e > BigInt(0)) {
      if (e & BigInt(1)) {
        result = (result * b) % mod;
      }
      b = (b * b) % mod;
      e = e >> BigInt(1);
    }
    return result;
  }

  /** Bit length of a non-negative bigint (Dart `BigInt.bitLength` semantics: 0 -> 0). */
  static bitLength(number: bigint): number {
    if (number <= BigInt(0)) {
      return 0;
    }
    return number.toString(2).length;
  }

  /** Big-endian minimal bytes of a non-negative BigInt (upstream encodeBigInt). */
  static encodeBigInt(number: bigint): Uint8Array {
    const byteMask: bigint = BigInt(0xff);
    const size: number = Math.floor((Srp.bitLength(number) + 7) / 8);
    if (size === 0) {
      return new Uint8Array(0);
    }
    const result = new Uint8Array(size);
    let n: bigint = number;
    for (let i = size - 1; i >= 0; i--) {
      result[i] = Number(n & byteMask);
      n = n >> BigInt(8);
    }
    return result;
  }

  static decodeBigInt(bytes: Uint8Array): bigint {
    let result: bigint = BigInt(0);
    for (let i = 0; i < bytes.length; i++) {
      result = (result << BigInt(8)) | BigInt(bytes[i]);
    }
    return result;
  }

  /** Left-pad big-endian bytes to `length` (no truncation if longer). */
  static getPadded(n: bigint, length: number): Uint8Array {
    const bs: Uint8Array = Srp.encodeBigInt(n);
    if (bs.length < length) {
      const tmp = new Uint8Array(length);
      const start = length - bs.length;
      for (let i = 0; start + i < length; i++) {
        tmp[start + i] = bs[i];
      }
      return tmp;
    }
    return bs;
  }

  static async sha256(parts: Uint8Array[]): Promise<Uint8Array> {
    let total: number = 0;
    for (let i = 0; i < parts.length; i++) {
      total += parts[i].length;
    }
    const all: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (let i = 0; i < parts.length; i++) {
      all.set(parts[i], offset);
      offset += parts[i].length;
    }
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: all } as cryptoFramework.DataBlob);
    const out = await md.digest();
    return out.data;
  }

  /** x = H(salt || H(identity || ':' || password)) */
  static async calculateX(salt: Uint8Array, identity: Uint8Array,
    password: Uint8Array): Promise<bigint> {
    const colon: Uint8Array = new Uint8Array([0x3a]); // ':'
    const inner: Uint8Array = await Srp.sha256([identity, colon, password]);
    const outer: Uint8Array = await Srp.sha256([salt, inner]);
    return Srp.decodeBigInt(outer);
  }

  /** Verifier v = g^x mod N. */
  static async generateVerifier(salt: Uint8Array, identity: Uint8Array,
    password: Uint8Array): Promise<bigint> {
    const x = await Srp.calculateX(salt, identity, password);
    return Srp.modPow(Srp.g, x, Srp.N);
  }

  /** k = H(pad(N) || pad(g)) */
  static async calculateK(): Promise<bigint> {
    const nBytes = Srp.getPadded(Srp.N, PAD_LENGTH);
    const gBytes = Srp.getPadded(Srp.g, PAD_LENGTH);
    const hash = await Srp.sha256([nBytes, gBytes]);
    return Srp.decodeBigInt(hash);
  }

  /** u = H(pad(A) || pad(B)) */
  static async calculateU(A: bigint, B: bigint): Promise<bigint> {
    const aBytes = Srp.getPadded(A, PAD_LENGTH);
    const bBytes = Srp.getPadded(B, PAD_LENGTH);
    const hash = await Srp.sha256([aBytes, bBytes]);
    return Srp.decodeBigInt(hash);
  }

  /**
   * Reduce and validate a peer-supplied public value — the port of pointycastle
   * `SRP6Util.validatePublicValue` (`.upstream/pub/lib/srp/srp6_util.dart:69-78`):
   *
   *   val = val % N;
   *   if (val == 0) throw Exception('Invalid public value: 0');
   *   return val;
   *
   * Dart's `%` always yields a non-negative result for a positive modulus, so the
   * negative-residue branch reproduces that semantics explicitly rather than
   * relying on `%` behaving the same way for bigint.
   *
   * CALLERS MUST USE THE RETURNED VALUE, not the argument. Upstream stores the
   * reduced value as `B` and computes BOTH `u` and `M1` from it
   * (srp6_client.dart:57-63, then :37-46) — so reducing for `calculateSecret`
   * while still hashing the raw value into `M1` would be a parity bug, not a
   * partial fix.
   */
  static validatePublicValue(value: bigint): bigint {
    let reduced: bigint = value % Srp.N;
    if (reduced < BigInt(0)) {
      reduced = reduced + Srp.N;
    }
    if (reduced === BigInt(0)) {
      throw new Error('Invalid public value: 0');
    }
    return reduced;
  }

  /**
   * Guard for `calculateSecret` / `calculateM1`: the public value must already be
   * reduced into [1, N-1].
   *
   * This makes it structurally impossible to compute `S` from a reduced `B` while
   * hashing a raw one into `M1` — a raw value fails in both. It is not a
   * re-reduction: silently reducing here would reintroduce exactly the
   * divergence this guard prevents. An honest server always sends B in range, so
   * this never rejects a valid exchange.
   */
  private static requireReducedPublicValue(B: bigint): void {
    if (B <= BigInt(0) || B >= Srp.N) {
      throw new Error('SRP public value B must be reduced into [1, N-1] before use');
    }
  }

  /** S = (B - k*g^x mod N) ^ (a + u*x) mod N */
  static async calculateSecret(B: bigint, A: bigint, a: bigint, x: bigint): Promise<bigint> {
    Srp.requireReducedPublicValue(B);
    const k: bigint = await Srp.calculateK();
    const u: bigint = await Srp.calculateU(A, B);
    const exp: bigint = u * x + a;
    const gx: bigint = Srp.modPow(Srp.g, x, Srp.N);
    const tmp: bigint = (gx * (k % Srp.N)) % Srp.N;
    let base: bigint = (B - tmp) % Srp.N;
    if (base < BigInt(0)) {
      base = base + Srp.N;
    }
    const S: bigint = Srp.modPow(base, exp, Srp.N);
    return S;
  }

  /** M1 = H(pad(A) || pad(B) || pad(S)) */
  static async calculateM1(A: bigint, B: bigint, S: bigint): Promise<bigint> {
    Srp.requireReducedPublicValue(B);
    const aBytes = Srp.getPadded(A, PAD_LENGTH);
    const bBytes = Srp.getPadded(B, PAD_LENGTH);
    const sBytes = Srp.getPadded(S, PAD_LENGTH);
    const hash = await Srp.sha256([aBytes, bBytes, sBytes]);
    return Srp.decodeBigInt(hash);
  }

  /** Full client login credential generation: returns {a, A, x}. */
  static async generateCredentials(salt: Uint8Array, identity: Uint8Array,
    password: Uint8Array, randomBytes32: () => Uint8Array): Promise<SrpCredentials> {
    const x = await Srp.calculateX(salt, identity, password);
    const minBits: number = Math.min(256, Math.floor(Srp.N.toString(2).length / 2));
    const min: bigint = BigInt(1) << BigInt(minBits - 1);
    const max: bigint = Srp.N - BigInt(1);
    let a: bigint = BigInt(0);
    for (let attempt = 0; attempt < 1000; attempt++) {
      a = Srp.decodeBigInt(randomBytes32());
      if ((a.toString(2).length) > minBits) {
        a = a >> BigInt(a.toString(2).length - minBits);
      }
      if (a <= max && a >= min) {
        break;
      }
      a = BigInt(0);
    }
    if (a === BigInt(0) && min !== BigInt(0)) {
      throw new Error('Failed to generate SRP private value');
    }
    const A: bigint = Srp.modPow(Srp.g, a, Srp.N);
    return new SrpCredentials(a, A, x);
  }
}

export class SrpCredentials {
  a: bigint;
  A: bigint;
  x: bigint;

  constructor(a: bigint, A: bigint, x: bigint) {
    this.a = a;
    this.A = A;
    this.x = x;
  }
}