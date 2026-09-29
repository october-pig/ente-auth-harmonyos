/**
 * Steam TOTP — mirror of `steam_totp` Dart package v0.0.2 used by upstream
 * (`ente@3cc9103a3126de07f79a4465cf0b9922903de54b`) via
 * `mobile/apps/auth/lib/utils/totp_util.dart`:
 *
 *   time = unixSeconds ~/ 30
 *   hmac = HMAC-SHA1(base32.decode(secret), 8-byte big-endian time)
 *   b = hmac[19] & 0x0F
 *   codePoint = (hmac[b] & 0x7F) << 24 | hmac[b+1] << 16 | hmac[b+2] << 8 | hmac[b+3]
 *   5 chars: steamChars[codePoint % 26], codePoint ~/= 26
 *
 * NOTE: SteamTOTP decodes the secret WITHOUT uppercasing it first (unlike the
 * otp package path); upstream stores secrets already sanitized (uppercase),
 * and code.secret is passed straight through, so we mirror "decode as-is".
 */
import { Base32 } from './Base32';
import { Otp } from './Otp';

export class SteamTotp {
  static readonly STEAM_CHARS: string = '23456789BCDFGHJKMNPQRTVWXY';
  static readonly PERIOD: number = 30;

  private readonly secret: string;
  private readonly sharedSecretArray: Uint8Array;

  constructor(secret: string) {
    if (secret.length === 0) {
      throw new Error('secret must not be empty.');
    }
    try {
      this.sharedSecretArray = Base32.decode(secret);
      if (this.sharedSecretArray.length === 0) {
        throw new Error('empty');
      }
    } catch (e) {
      throw new Error('secret must be valid base32.');
    }
    this.secret = secret;
  }

  /** Generates the 5-character Steam code for the given unix seconds. */
  async generate(unixSeconds: number): Promise<string> {
    let time: number = Math.trunc(unixSeconds);
    if (time < 0) {
      throw new Error('unixSeconds must be non-negative.');
    }
    time = Math.floor(time / SteamTotp.PERIOD);
    const timeArray: Uint8Array = Otp.int2bytes(time);
    const hmac: Uint8Array = await Otp.hmacDigest('SHA1', this.sharedSecretArray, timeArray);
    const b: number = (hmac[19] & 0xF) % 0xFF;
    let codePoint: number = ((hmac[b] & 0x7F) << 24) |
      ((hmac[b + 1] & 0xFF) << 16) |
      ((hmac[b + 2] & 0xFF) << 8) |
      (hmac[b + 3] & 0xFF);
    let out: string = '';
    for (let i = 0; i < 5; i++) {
      out = out + SteamTotp.STEAM_CHARS.charAt(codePoint % SteamTotp.STEAM_CHARS.length);
      codePoint = Math.floor(codePoint / SteamTotp.STEAM_CHARS.length);
    }
    return out;
  }
}