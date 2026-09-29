/**
 * RFC 4226 / RFC 6238 one-time password generation.
 *
 * Behavior mirrors the `otp` Dart package v3.2.0 (locked by upstream
 * `ente@3cc9103a3126de07f79a4465cf0b9922903de54b` via mobile/pubspec.lock).
 * The auth app always uses the `isGoogle: true` path (base32 secret); the
 * raw path (`asBase32: false`) exists for byte-parity with the package's
 * non-Google behavior (UTF-8 secret, TOTP repeats/truncates the secret to the
 * digest length; HOTP does not pad):
 *
 *   generateTOTPCodeString: counter = floor((millis ~/ 1000) ~/ interval)
 *   generateHOTPCodeString: counter as-is, 8-byte big-endian
 *   dynamic truncation: offset = lastHashByte & 0x0f, 31-bit binary,
 *   otp = binary % 10^length, zero-padded to length.
 *
 * HMAC digests use the HarmonyOS Crypto Architecture Kit.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Base32 } from './Base32';
import { OtpAlgorithm } from './OtpTypes';
import { Utf8Strict } from '../models/UriComponent';

const DEFAULT_DIGITS: number = 6;

export class Otp {
  /**
   * Generates a time-based one time password from `timeMs` (milliseconds since
   * epoch, optionally adjusted by the server time offset by the caller).
   */
  static async generateTOTPCodeString(secret: string, timeMs: number,
    length: number = DEFAULT_DIGITS, interval: number = 30,
    algorithm: OtpAlgorithm = OtpAlgorithm.sha1, asBase32: boolean = true): Promise<string> {
    const time: number = Math.trunc(timeMs / 1000);
    const counter: number = Math.floor(time / interval);
    const code: number = await Otp.generateCode(secret, counter, length, algorithm, false, asBase32);
    return Otp.padStartLeft(code.toString(), length, '0');
  }

  /** Generates an HMAC-based one time password for the given counter. */
  static async generateHOTPCodeString(secret: string, counter: number,
    length: number = DEFAULT_DIGITS, algorithm: OtpAlgorithm = OtpAlgorithm.sha1,
    asBase32: boolean = true): Promise<string> {
    const code: number = await Otp.generateCode(secret, counter, length, algorithm, true, asBase32);
    return Otp.padStartLeft(code.toString(), length, '0');
  }

  /** Core: derive key bytes, HMAC over the 8-byte big-endian counter, dynamic truncation. */
  static async generateCode(secret: string, counter: number, length: number,
    algorithm: OtpAlgorithm, isHOTP: boolean = false, asBase32: boolean = true): Promise<number> {
    let digits: number = length;
    if (digits <= 0) {
      digits = DEFAULT_DIGITS;
    }
    let secretList: Uint8Array;
    if (asBase32) {
      secretList = Base32.decode(secret.toUpperCase());
    } else {
      secretList = Utf8Strict.encode(secret);
      if (!isHOTP) {
        secretList = Otp.padSecret(secretList, Otp.algorithmByteLength(algorithm));
      }
    }
    const timebytes: Uint8Array = Otp.int2bytes(Math.trunc(counter));
    const digest: Uint8Array = await Otp.hmacDigest(Otp.algorithmName(algorithm), secretList, timebytes);
    const offset: number = digest[digest.length - 1] & 0x0f;
    const binary: number = ((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff);
    return binary % Math.pow(10, digits);
  }

  /** Standard RFC 4648 base32 encode used for secrets. */
  static encodeSecret(bytes: Uint8Array): string {
    return Base32.encode(bytes);
  }

  /** 8-byte big-endian representation of a (non-negative) counter. */
  static int2bytes(value: number): Uint8Array {
    const byteArray = new Uint8Array(8);
    let v: number = value;
    for (let index: number = 7; index >= 0; index--) {
      let byte: number = v % 256;
      if (byte < 0) {
        byte += 256;
      }
      byteArray[index] = byte;
      v = Math.trunc((v - byte) / 256);
    }
    return byteArray;
  }

  /**
   * otp 3.2.0 `_padSecret`: repeat the secret until it reaches the digest
   * byte length, then truncate. Empty input stays empty.
   */
  static padSecret(secret: Uint8Array, targetLength: number): Uint8Array {
    if (secret.length >= targetLength) {
      return secret;
    }
    if (secret.length === 0) {
      return secret;
    }
    const newList: number[] = [];
    for (let i = 0; i * secret.length < targetLength; i++) {
      for (let j = 0; j < secret.length; j++) {
        newList.push(secret[j]);
      }
    }
    return Uint8Array.from(newList.slice(0, targetLength));
  }

  static algorithmByteLength(algorithm: OtpAlgorithm): number {
    switch (algorithm) {
      case OtpAlgorithm.sha256:
        return 32;
      case OtpAlgorithm.sha512:
        return 64;
      default:
        return 20;
    }
  }

  static algorithmName(algorithm: OtpAlgorithm): string {
    switch (algorithm) {
      case OtpAlgorithm.sha256:
        return 'SHA256';
      case OtpAlgorithm.sha512:
        return 'SHA512';
      default:
        return 'SHA1';
    }
  }

  private static padStartLeft(s: string, length: number, pad: string): string {
    if (s.length >= length) {
      return s;
    }
    let out: string = s;
    while (out.length < length) {
      out = pad + out;
    }
    return out;
  }

  /** HMAC digest via Crypto Architecture Kit. */
  static async hmacDigest(algo: string, key: Uint8Array, msg: Uint8Array): Promise<Uint8Array> {
    const mac: cryptoFramework.Mac = cryptoFramework.createMac(algo.toUpperCase());
    const gen: cryptoFramework.SymKeyGenerator = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey: cryptoFramework.SymKey = await gen.convertKey({ data: key } as cryptoFramework.DataBlob);
    await mac.init(symKey);
    await mac.update({ data: msg } as cryptoFramework.DataBlob);
    const out: cryptoFramework.DataBlob = await mac.doFinal();
    return out.data;
  }
}