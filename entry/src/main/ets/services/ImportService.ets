/**
 * ImportService — mirrors upstream `ui/settings/data/import/`:
 *  - Plain text (otpauth lines or Ente JSON {items:[{rawData, display}]})
 *  - Ente encrypted JSON (EnteAuthExport v1, Argon2id KEK)
 *  - Google Authenticator migration URI / otpauth-migration://
 *  - JSON formats: Bitwarden {items, folders}, LastPass {accounts}, Raivo []
 *  Unsupported formats listed with the upstream-visible labels; their entries
 *  throw a descriptive error (documented DEFERRED formats).
 */
import { Code } from '../models/Code';
import { CodeStore } from '../store/CodeStore';
import { CryptoUtil } from '../crypto/CryptoUtil';
import { OtpType, OtpAlgorithm } from '../otp/OtpTypes';
import { GoogleAuthImport } from './GoogleAuthImport';

export class ImportEntryParseException extends Error {
  entry: string;

  constructor(entry: string, cause: Error) {
    super(`Could not parse entry: ${cause.message}`);
    this.entry = entry;
  }
}

export class IncorrectPasswordError extends Error {
  constructor() {
    super('Incorrect password');
  }
}

function sanitize(secret: string): string {
  return secret.toUpperCase().trim().replaceAll(' ', '');
}

function buildImportOtpUri(kind: OtpType, issuer: string, account: string, secret: string,
  algorithm: OtpAlgorithm, digits: number, period: number, counter: number,
  allowSteam: boolean): string {
  let k: OtpType = kind;
  if (k !== OtpType.totp && k !== OtpType.hotp) {
    if (k === OtpType.steam && !allowSteam) {
      throw new Error(`Invalid OTP type: ${k.toString()}`);
    }
  }
  if (k === OtpType.steam || k === OtpType.totp) {
    if (k === OtpType.steam && !allowSteam) {
      throw new Error(`Invalid OTP type: ${k.toString()}`);
    }
    let d = digits;
    if (d === 0) {
      d = 6;
    }
    if (d < 0 || d > 10) {
      throw new Error(`Invalid OTP digits: ${d}`);
    }
    let p = period;
    if (p === 0) {
      p = 30;
    }
    if (p < 0) {
      throw new Error('Invalid OTP period');
    }
    return `otpauth://${k}/${issuer}:${account}?secret=${sanitize(secret)}&issuer=${issuer}` +
      `&algorithm=${algorithm.toString().toUpperCase()}&digits=${d}&period=${p}`;
  }
  // HOTP
  let d = digits;
  if (d === 0) {
    d = 6;
  }
  if (d < 0 || d > 10) {
    throw new Error(`Invalid OTP digits: ${d}`);
  }
  let c = counter;
  if (c === 0) {
    c = 0;
  }
  if (c < 0) {
    throw new Error('Invalid OTP counter');
  }
  return `otpauth://hotp/${issuer}:${account}?secret=${sanitize(secret)}&issuer=${issuer}` +
    `&algorithm=${algorithm.toString().toUpperCase()}&digits=${d}&counter=${c}`;
}

export class ImportService {
  static async saveImportedCodes(codes: Code[]): Promise<number> {
    let count = 0;
    for (let i = 0; i < codes.length; i++) {
      const result = await CodeStore.instance.addCode(codes[i], false);
      if (result === 0 /* newCode */) {
        count++;
      }
    }
    return count;
  }

  /** Plain text: otpauth lines or Ente JSON {items}. */
  static parsePlainText(content: string): Code[] {
    const trimmed: string = content.trim();
    if (trimmed.startsWith('otpauth://')) {
      const parts: string[] = trimmed.split(/(?:\r\n?|\n)|,(?=\s*otpauth:\/\/)/);
      const codes: Code[] = [];
      for (let i = 0; i < parts.length; i++) {
        const line: string = parts[i].trim();
        if (line.length === 0) {
          continue;
        }
        try {
          codes.push(Code.fromOTPAuthUrl(line));
        } catch (e) {
          // skip malformed entries (upstream logs and skips)
        }
      }
      return codes;
    }
    const json: object = JSON.parse(trimmed) as object;
    const map: Record<string, Object> = json as Record<string, Object>;
    const items = map['items'] as object[];
    const codes: Code[] = [];
    if (items === undefined) {
      return codes;
    }
    for (let i = 0; i < items.length; i++) {
      codes.push(Code.fromExportJson(items[i]));
    }
    return codes;
  }

  /** EnteAuthExport v1 encrypted JSON. */
  static async parseEnteEncrypted(content: string, password: string): Promise<Code[]> {
    const json: Record<string, Object> = JSON.parse(content) as Record<string, Object>;
    const kdfParams = json['kdfParams'] as Record<string, Object>;
    const salt: Uint8Array = CryptoUtil.base642bin(kdfParams['salt'] as string);
    const memLimit: number = kdfParams['memLimit'] as number;
    const opsLimit: number = kdfParams['opsLimit'] as number;
    const encryptedData: Uint8Array = CryptoUtil.base642bin(json['encryptedData'] as string);
    const nonce: Uint8Array = CryptoUtil.base642bin(json['encryptionNonce'] as string);
    const key: Uint8Array = await CryptoUtil.deriveKey(CryptoUtil.strToBin(password), salt, memLimit, opsLimit);
    let plaintext: Uint8Array;
    try {
      plaintext = await CryptoUtil.decryptData(encryptedData, key, nonce);
    } catch (e) {
      throw new IncorrectPasswordError();
    }
    const text: string = decodeUtf8(plaintext);
    const lines: string[] = text.split('\n');
    const codes: Code[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      try {
        let raw: string = line;
        if (raw.startsWith('"') && raw.endsWith('"')) {
          raw = JSON.parse(raw) as string;
        }
        codes.push(Code.fromOTPAuthUrl(raw));
      } catch (e) {
        // skip
      }
    }
    return codes;
  }

  /** Bitwarden JSON {items:[...], folders:[...]}. */
  static parseBitwarden(content: string): Code[] {
    const json: Record<string, Object> = JSON.parse(content) as Record<string, Object>;
    const items = json['items'] as object[];
    const folderMap: Map<string, string> = new Map<string, string>();
    const folders = json['folders'] as object[];
    if (folders !== undefined) {
      for (let i = 0; i < folders.length; i++) {
        const f = folders[i] as Record<string, Object>;
        folderMap.set(f['id'] as string, f['name'] as string);
      }
    }
    const codes: Code[] = [];
    if (items === undefined) {
      return codes;
    }
    for (let i = 0; i < items.length; i++) {
      const item = items[i] as Record<string, Object>;
      const login = item['login'] as Record<string, Object>;
      if (login === undefined || login['totp'] === undefined) {
        continue;
      }
      const totpValue: string = login['totp'] as string;
      const name: string = (item['name'] as string) ?? '';
      const username: string = (login['username'] as string) ?? '';
      const notes: string = (item['notes'] as string) ?? '';
      const folderId = item['folderId'] as string;
      let code: Code;
      try {
        if (totpValue.startsWith('otpauth://')) {
          code = Code.fromOTPAuthUrl(totpValue);
        } else if (totpValue.startsWith('steam://')) {
          const secret = totpValue.substring('steam://'.length);
          code = Code.fromAccountAndSecret(OtpType.steam, username, name, secret, undefined, 5);
        } else {
          code = Code.fromAccountAndSecret(OtpType.totp, username, name, totpValue, undefined, 6);
        }
      } catch (e) {
        throw new ImportEntryParseException(JSON.stringify(item), e as Error);
      }
      const tags: string[] = [];
      if (folderId !== undefined && folderId !== null && folderMap.has(folderId)) {
        tags.push(folderMap.get(folderId) as string);
      }
      if (notes.length > 0) {
        code.display.note = notes;
      }
      if (tags.length > 0) {
        code.display.tags = tags;
      }
      codes.push(code);
    }
    return codes;
  }

  /** LastPass JSON {accounts:[...]}. */
  static parseLastPass(content: string): Code[] {
    const json: Record<string, Object> = JSON.parse(content) as Record<string, Object>;
    const accounts = json['accounts'] as object[];
    const codes: Code[] = [];
    if (accounts === undefined) {
      return codes;
    }
    for (let i = 0; i < accounts.length; i++) {
      const acc = accounts[i] as Record<string, Object>;
      const secret: string = (acc['secret'] as string) ?? '';
      if (secret.length === 0) {
        continue;
      }
      const issuer: string = (acc['issuerName'] as string) ?? '';
      const account: string = (acc['userName'] as string) ?? '';
      const algorithm: OtpAlgorithm = ((acc['algorithm'] as string) ?? 'SHA1').toLowerCase() === 'sha256'
        ? OtpAlgorithm.sha256 : OtpAlgorithm.sha1;
      const digits: number = (acc['digits'] as number) ?? 6;
      const timer: number = (acc['timeStep'] as number) ?? 30;
      const raw: string = buildImportOtpUri(OtpType.totp, issuer, account, secret, algorithm,
        digits, timer, 0, false);
      codes.push(Code.fromOTPAuthUrl(raw));
    }
    return codes;
  }

  /** Raivo OTP JSON array. */
  static parseRaivo(content: string): Code[] {
    const list = JSON.parse(content) as object[];
    const codes: Code[] = [];
    if (list === undefined) {
      return codes;
    }
    for (let i = 0; i < list.length; i++) {
      const entry = list[i] as Record<string, Object>;
      const secret: string = (entry['secret'] as string) ?? '';
      if (secret.length === 0) {
        continue;
      }
      const kind: string = (entry['kind'] as string) ?? 'totp';
      const issuer: string = (entry['issuer'] as string) ?? '';
      const account: string = (entry['account'] as string) ?? '';
      const algorithm: OtpAlgorithm = ((entry['algorithm'] as string) ?? 'SHA1').toLowerCase() === 'sha256'
        ? OtpAlgorithm.sha256 : OtpAlgorithm.sha1;
      const digits: number = (entry['digits'] as number) ?? 6;
      const timer: number = (entry['timer'] as number) ?? 30;
      const counter: number = (entry['counter'] as number) ?? 0;
      const kindEnum: OtpType = kind.toLowerCase() === 'hotp' ? OtpType.hotp :
        (kind.toLowerCase() === 'steam' ? OtpType.steam : OtpType.totp);
      const raw: string = buildImportOtpUri(kindEnum, issuer, account, secret, algorithm,
        digits, timer, counter, false);
      codes.push(Code.fromOTPAuthUrl(raw));
    }
    return codes;
  }

  /** Google Authenticator migration: starts with otpauth-migration://offline. */
  static parseGoogleAuth(content: string): Code[] {
    if (content.startsWith('otpauth-migration://offline')) {
      return GoogleAuthImport.importFromMigrationUri(content);
    }
    const json: Record<string, Object> = JSON.parse(content) as Record<string, Object>;
    throw new Error('Unsupported Google Authenticator format');
  }
}

function decodeUtf8(bytes: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      i++;
    } else if ((b0 & 0xE0) === 0xC0) {
      out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if ((b0 & 0xF0) === 0xE0) {
      out += String.fromCharCode(((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
      i += 3;
    } else {
      const cp: number = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) |
        ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
      const adj: number = cp - 0x10000;
      out += String.fromCharCode(0xD800 + (adj >> 10), 0xDC00 + (adj & 0x3FF));
      i += 4;
    }
  }
  return out;
}