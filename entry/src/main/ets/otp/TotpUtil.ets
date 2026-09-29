/**
 * TOTP/HOTP/Steam code generation entry points — mirror of upstream
 * `mobile/apps/auth/lib/utils/totp_util.dart`
 * (`ente@3cc9103a3126de07f79a4465cf0b9922903de54b`).
 *
 * `millisecondsSinceEpoch()` = wall clock (ms) + server time offset (ms).
 * The offset is computed by the sync layer from the server `timestamp`
 * (microseconds → ms), stored by PreferenceService under `local_time_offset`.
 */
import { Code } from '../models/Code';
import { OtpType } from './OtpTypes';
import { Otp } from './Otp';
import { SteamTotp } from './SteamTotp';

/** Server time offset holder (set by sync; persisted by PreferenceService). */
export class TimeOffset {
  private static offsetMs: number = 0;

  static setOffset(ms: number): void {
    TimeOffset.offsetMs = ms;
  }

  static getOffset(): number {
    return TimeOffset.offsetMs;
  }
}

export function millisecondsSinceEpoch(): number {
  return Date.now() + TimeOffset.getOffset();
}

export async function getOTP(code: Code): Promise<string> {
  if (code.type === OtpType.steam || code.issuer.toLowerCase() === 'steam') {
    return getSteamCode(code, false);
  }
  if (code.type === OtpType.hotp) {
    return getHOTPCode(code);
  }
  return Otp.generateTOTPCodeString(getSanitizedSecretPrivate(code.secret),
    millisecondsSinceEpoch(), code.digits, code.period, code.algorithm);
}

async function getHOTPCode(code: Code): Promise<string> {
  return Otp.generateHOTPCodeString(getSanitizedSecretPrivate(code.secret),
    code.counter, code.digits, code.algorithm);
}

async function getSteamCode(code: Code, isNext: boolean): Promise<string> {
  const steamTotp: SteamTotp = new SteamTotp(code.secret);
  return steamTotp.generate(Math.floor(millisecondsSinceEpoch() / 1000) + (isNext ? code.period : 0));
}

export async function getNextTotp(code: Code): Promise<string> {
  if (code.type === OtpType.steam || code.issuer.toLowerCase() === 'steam') {
    return getSteamCode(code, true);
  }
  return Otp.generateTOTPCodeString(getSanitizedSecretPrivate(code.secret),
    millisecondsSinceEpoch() + code.period * 1000, code.digits, code.period, code.algorithm);
}

/**
 * Returns (startTime, codes) for `count` future TOTP codes starting at the
 * current time step (mirrors upstream generateFutureTotpCodes).
 */
export async function generateFutureTotpCodes(code: Code, count: number): Promise<[number, string[]]> {
  const startTime: number = Math.floor(Math.floor(millisecondsSinceEpoch() / 1000) / code.period) *
    code.period * 1000;
  const secret: string = getSanitizedSecretPrivate(code.secret);
  const codes: string[] = [];
  if (code.type === OtpType.steam || code.issuer.toLowerCase() === 'steam') {
    const steamTotp: SteamTotp = new SteamTotp(code.secret);
    for (let i = 0; i < count; i++) {
      const generatedTime: number = startTime + code.period * 1000 * i;
      codes.push(await steamTotp.generate(Math.floor(generatedTime / 1000)));
    }
  } else {
    for (let i = 0; i < count; i++) {
      const generatedTime: number = startTime + code.period * 1000 * i;
      codes.push(await Otp.generateTOTPCodeString(secret, generatedTime,
        code.digits, code.period, code.algorithm));
    }
  }
    return [startTime, codes];
}

function getSanitizedSecretPrivate(secret: string): string {
  return secret.toUpperCase().trim().replaceAll(' ', '');
}