/**
 * Base32 (RFC 4648) encode/decode.
 *
 * Behavior mirrors `base32` Dart package v2.1.3 (locked by upstream
 * `ente@3cc9103a3126de07f79a4465cf0b9922903de54b` via mobile/pubspec.lock),
 * standardRFC4648 encoding only:
 *  - decode pads input with '=' to a multiple of 8 before validation;
 *  - input must match ^[A-Z2-7=]+$ and have EVEN length, otherwise it throws
 *    (upstream: FormatException);
 *  - '=' terminates the decoded region; only remainder lengths 2/4/5/7 after
 *    full 8-char groups are accepted.
 */
export class Base32 {
  private static readonly CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  private static readonly DECODE_MAP: Map<string, number> = new Map<string, number>();

  private static initDecodeMap(): void {
    if (Base32.DECODE_MAP.size === 0) {
      for (let i = 0; i < 32; i++) {
        Base32.DECODE_MAP.set(Base32.CHARS.charAt(i), i);
      }
    }
  }

  /** Decodes a base32 string to bytes. Throws Error('Invalid Base32 characters') on invalid input. */
  static decode(input: string): Uint8Array {
    Base32.initDecodeMap();
    let b32: string = input;
    if (b32.length === 0) {
      return new Uint8Array(0);
    }
    // Pad to a multiple of 8 with '=' (getPadded == true for RFC4648).
    const neededPadding: number = (8 - b32.length % 8) % 8;
    if (neededPadding > 0) {
      b32 = b32.padEnd(b32.length + neededPadding, '=');
    }
    if (!Base32.isValid(b32)) {
      throw new Error('Invalid Base32 characters');
    }
    let length: number = b32.indexOf('=');
    if (length === -1) {
      length = b32.length;
    }
    const count: number = (length >> 3) << 3;
    const bytes: number[] = [];
    let i: number = 0;
    while (i < count) {
      const v1 = Base32.decodeMapGet(b32.charAt(i++));
      const v2 = Base32.decodeMapGet(b32.charAt(i++));
      const v3 = Base32.decodeMapGet(b32.charAt(i++));
      const v4 = Base32.decodeMapGet(b32.charAt(i++));
      const v5 = Base32.decodeMapGet(b32.charAt(i++));
      const v6 = Base32.decodeMapGet(b32.charAt(i++));
      const v7 = Base32.decodeMapGet(b32.charAt(i++));
      const v8 = Base32.decodeMapGet(b32.charAt(i++));
      bytes.push((v1 << 3 | v2 >> 2) & 255);
      bytes.push((v2 << 6 | v3 << 1 | v4 >> 4) & 255);
      bytes.push((v4 << 4 | v5 >> 1) & 255);
      bytes.push((v5 << 7 | v6 << 2 | v7 >> 3) & 255);
      bytes.push((v7 << 5 | v8) & 255);
    }
    const remain: number = length - count;
    if (remain === 2) {
      const v1 = Base32.decodeMapGet(b32.charAt(i++));
      const v2 = Base32.decodeMapGet(b32.charAt(i++));
      bytes.push((v1 << 3 | v2 >> 2) & 255);
    } else if (remain === 4) {
      const v1 = Base32.decodeMapGet(b32.charAt(i++));
      const v2 = Base32.decodeMapGet(b32.charAt(i++));
      const v3 = Base32.decodeMapGet(b32.charAt(i++));
      const v4 = Base32.decodeMapGet(b32.charAt(i++));
      bytes.push((v1 << 3 | v2 >> 2) & 255);
      bytes.push((v2 << 6 | v3 << 1 | v4 >> 4) & 255);
    } else if (remain === 5) {
      const v1 = Base32.decodeMapGet(b32.charAt(i++));
      const v2 = Base32.decodeMapGet(b32.charAt(i++));
      const v3 = Base32.decodeMapGet(b32.charAt(i++));
      const v4 = Base32.decodeMapGet(b32.charAt(i++));
      const v5 = Base32.decodeMapGet(b32.charAt(i++));
      bytes.push((v1 << 3 | v2 >> 2) & 255);
      bytes.push((v2 << 6 | v3 << 1 | v4 >> 4) & 255);
      bytes.push((v4 << 4 | v5 >> 1) & 255);
    } else if (remain === 7) {
      const v1 = Base32.decodeMapGet(b32.charAt(i++));
      const v2 = Base32.decodeMapGet(b32.charAt(i++));
      const v3 = Base32.decodeMapGet(b32.charAt(i++));
      const v4 = Base32.decodeMapGet(b32.charAt(i++));
      const v5 = Base32.decodeMapGet(b32.charAt(i++));
      const v6 = Base32.decodeMapGet(b32.charAt(i++));
      const v7 = Base32.decodeMapGet(b32.charAt(i++));
      bytes.push((v1 << 3 | v2 >> 2) & 255);
      bytes.push((v2 << 6 | v3 << 1 | v4 >> 4) & 255);
      bytes.push((v4 << 4 | v5 >> 1) & 255);
      bytes.push((v5 << 7 | v6 << 2 | v7 >> 3) & 255);
    }
    return Uint8Array.from(bytes);
  }

  private static decodeMapGet(c: string): number {
    const v = Base32.DECODE_MAP.get(c);
    return v === undefined ? 0 : v;
  }

  private static isValid(b32: string): boolean {
    const re = /^[A-Z2-7=]+$/;
    if (b32.length % 2 !== 0 || !re.test(b32)) {
      return false;
    }
    return true;
  }

  /** Encodes bytes to base32 (RFC 4648, with padding, matching base32 2.1.3 standardRFC4648). */
  static encode(bytesList: Uint8Array): string {
    let i: number = 0;
    const count: number = Math.floor(bytesList.length / 5) * 5;
    let out: string = '';
    while (i < count) {
      const v1 = bytesList[i++];
      const v2 = bytesList[i++];
      const v3 = bytesList[i++];
      const v4 = bytesList[i++];
      const v5 = bytesList[i++];
      out = out +
        Base32.CHARS.charAt(v1 >> 3) +
        Base32.CHARS.charAt((v1 << 2 | v2 >> 6) & 31) +
        Base32.CHARS.charAt((v2 >> 1) & 31) +
        Base32.CHARS.charAt((v2 << 4 | v3 >> 4) & 31) +
        Base32.CHARS.charAt((v3 << 1 | v4 >> 7) & 31) +
        Base32.CHARS.charAt((v4 >> 2) & 31) +
        Base32.CHARS.charAt((v4 << 3 | v5 >> 5) & 31) +
        Base32.CHARS.charAt(v5 & 31);
    }
    const remain: number = bytesList.length - count;
    if (remain === 1) {
      const v1 = bytesList[i];
      out = out + Base32.CHARS.charAt(v1 >> 3) + Base32.CHARS.charAt((v1 << 2) & 31) + '======';
    } else if (remain === 2) {
      const v1 = bytesList[i++];
      const v2 = bytesList[i];
      out = out + Base32.CHARS.charAt(v1 >> 3) +
        Base32.CHARS.charAt((v1 << 2 | v2 >> 6) & 31) +
        Base32.CHARS.charAt((v2 >> 1) & 31) +
        Base32.CHARS.charAt((v2 << 4) & 31) + '====';
    } else if (remain === 3) {
      const v1 = bytesList[i++];
      const v2 = bytesList[i++];
      const v3 = bytesList[i];
      out = out + Base32.CHARS.charAt(v1 >> 3) +
        Base32.CHARS.charAt((v1 << 2 | v2 >> 6) & 31) +
        Base32.CHARS.charAt((v2 >> 1) & 31) +
        Base32.CHARS.charAt((v2 << 4 | v3 >> 4) & 31) +
        Base32.CHARS.charAt((v3 << 1) & 31) + '===';
    } else if (remain === 4) {
      const v1 = bytesList[i++];
      const v2 = bytesList[i++];
      const v3 = bytesList[i++];
      const v4 = bytesList[i];
      out = out + Base32.CHARS.charAt(v1 >> 3) +
        Base32.CHARS.charAt((v1 << 2 | v2 >> 6) & 31) +
        Base32.CHARS.charAt((v2 >> 1) & 31) +
        Base32.CHARS.charAt((v2 << 4 | v3 >> 4) & 31) +
        Base32.CHARS.charAt((v3 << 1 | v4 >> 7) & 31) +
        Base32.CHARS.charAt((v4 >> 2) & 31) +
        Base32.CHARS.charAt((v4 << 3) & 31) + '=';
    }
    return out;
  }
}