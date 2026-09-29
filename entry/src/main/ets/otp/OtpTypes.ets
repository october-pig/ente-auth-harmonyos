/**
 * OTP hash algorithms and code types, mirroring upstream
 * `mobile/apps/auth/lib/models/code.dart`:
 *   enum Type { totp, hotp, steam }
 *   enum Algorithm { sha1, sha256, sha512 }
 */
export enum OtpType {
  totp = 'totp',
  hotp = 'hotp',
  steam = 'steam',
}

export enum OtpAlgorithm {
  sha1 = 'sha1',
  sha256 = 'sha256',
  sha512 = 'sha512',
}

export class OtpTypeUtil {
  static isTOTPCompatible(t: OtpType): boolean {
    return t === OtpType.totp || t === OtpType.steam;
  }

  static canShareCodes(t: OtpType): boolean {
    return t === OtpType.totp || t === OtpType.steam;
  }
}