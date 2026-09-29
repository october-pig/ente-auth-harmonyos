/**
 * Logger — non-secret structured logging. NEVER log secrets (passwords, OTP
 * secrets, keys, tokens, decrypted payloads). Only metadata/state.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0E41; // 'ente'

export class Logger {
  static info(message: string): void {
    hilog.info(DOMAIN, 'EnteAuth', '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, 'EnteAuth', '%{public}s', message);
  }

  static error(message: string): void {
    hilog.error(DOMAIN, 'EnteAuth', '%{public}s', message);
  }
}