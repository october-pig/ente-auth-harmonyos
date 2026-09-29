/**
 * Code — mirror of upstream `mobile/apps/auth/lib/models/code.dart`
 * (`ente@3cc9103a3126de07f79a4465cf0b9922903de54b`).
 *
 * The OTP code domain model: parsed otpauth URI fields + display metadata,
 * with byte-compatible rawData serialization.
 */
import { OtpAlgorithm, OtpType } from '../otp/OtpTypes';
import { CodeDisplay } from './CodeDisplay';
import { UriComponent, Utf8Strict } from './UriComponent';
import { toError } from '../utils/Errors';

export class CodeParseFailure {
  readonly message: string;
  readonly rawData: string;

  constructor(message: string, rawData: string) {
    this.message = message;
    this.rawData = rawData;
  }
}

export class Code {
  static readonly defaultDigits: number = 6;
  static readonly steamDigits: number = 5;
  static readonly defaultPeriod: number = 30;

  generatedID: number | undefined;
  account: string;
  issuer: string;
  digits: number;
  period: number;
  secret: string;
  algorithm: OtpAlgorithm;
  type: OtpType;

  /** Original otpauth URL. */
  rawData: string;
  counter: number;
  hasSynced: boolean | undefined;

  display: CodeDisplay;

  /** Pending parse error (Code.withError). */
  err: string | undefined;

  get isPinned(): boolean {
    return this.display.pinned;
  }

  get isTrashed(): boolean {
    return this.display.trashed;
  }

  get note(): string {
    return this.display.note;
  }

  get hasError(): boolean {
    return this.err !== undefined;
  }

  /** Unsaved codes use rawData until the first save assigns generatedID. */
  get selectionKey(): string {
    return this.generatedID === undefined ? this.rawData : this.generatedID.toString();
  }

  get issuerAccount(): string {
    return this.account.length > 0 ? `${this.issuer} (${this.account})` : this.issuer;
  }

  constructor(account: string, issuer: string, digits: number, period: number,
    secret: string, algorithm: OtpAlgorithm, type: OtpType, counter: number,
    rawData: string, generatedID?: number, display?: CodeDisplay, err?: string) {
    this.account = account;
    this.issuer = issuer;
    this.digits = digits;
    this.period = period;
    this.secret = secret;
    this.algorithm = algorithm;
    this.type = type;
    this.counter = counter;
    this.rawData = rawData;
    this.generatedID = generatedID;
    this.display = display === undefined ? new CodeDisplay() : display;
    this.err = err;
  }

  static withError(error: string, rawData: string): Code {
    return new Code('', '', 0, 0, '', OtpAlgorithm.sha1, OtpType.totp, 0, rawData,
      undefined, new CodeDisplay(), error);
  }

  copyWith(account?: string, issuer?: string, digits?: number, period?: number,
    secret?: string, algorithm?: OtpAlgorithm, type?: OtpType, counter?: number,
    display?: CodeDisplay): Code {
    const updateAccount: string = account === undefined ? this.account : account;
    const updateIssuer: string = issuer === undefined ? this.issuer : issuer;
    const updatedDigits: number = digits === undefined ? this.digits : digits;
    const updatePeriod: number = period === undefined ? this.period : period;
    const updatedSecret: string = secret === undefined ? this.secret : secret;
    const updatedAlgo: OtpAlgorithm = algorithm === undefined ? this.algorithm : algorithm;
    const updatedType: OtpType = type === undefined ? this.type : type;
    const updatedCounter: number = counter === undefined ? this.counter : counter;
    const updatedDisplay: CodeDisplay = display === undefined ? this.display : display;
    const encodedIssuer: string = UriComponent.encodeQueryComponent(updateIssuer);
    let raw: string = `otpauth://${updatedType.toString()}/${updateIssuer}:${updateAccount}` +
      `?algorithm=${updatedAlgo.toString().toUpperCase()}&digits=${updatedDigits}` +
      `&issuer=${encodedIssuer}&period=${updatePeriod}&secret=${updatedSecret}`;
    if (updatedType === OtpType.hotp) {
      raw = raw + `&counter=${updatedCounter}`;
    }
    return new Code(updateAccount, updateIssuer, updatedDigits, updatePeriod,
      updatedSecret, updatedAlgo, updatedType, updatedCounter, raw,
      this.generatedID, updatedDisplay, this.err);
  }

  static fromAccountAndSecret(type: OtpType, account: string, issuer: string,
    secret: string, display: CodeDisplay | undefined, digits: number,
    algorithm: OtpAlgorithm = OtpAlgorithm.sha1, period: number = Code.defaultPeriod): Code {
    const encodedIssuer: string = UriComponent.encodeQueryComponent(issuer);
    const raw: string = `otpauth://${type.toString()}/${issuer}:${account}` +
      `?algorithm=${algorithm.toString().toUpperCase()}&digits=${digits}` +
      `&issuer=${encodedIssuer}&period=${period}&secret=${secret}`;
    return new Code(account, issuer, digits, period, secret, algorithm, type, 0, raw,
      undefined, display === undefined ? new CodeDisplay() : display);
  }

  static fromOTPAuthUrl(rawData: string, displayIn?: CodeDisplay | undefined): Code {
    try {
      return Code.parseOnce(rawData, displayIn);
    } catch (e) {
      // Retry after encoding an unescaped '#' in the account name.
      if (rawData.includes('#')) {
        return Code.parseOnce(rawData.replaceAll('#', '%23'), displayIn);
      } else {
        throw toError(e);
      }
    }
  }

  private static parseOnce(rawData: string, displayIn?: CodeDisplay | undefined): Code {
    const uri: UriComponent = UriComponent.parse(rawData);
    const issuer: string = Code.getIssuer(uri);
    const account: string = Code.getAccount(uri, issuer);
    let display: CodeDisplay;
    if (displayIn !== undefined) {
      display = displayIn;
    } else {
      const fromUri = CodeDisplay.fromUri(uri);
      display = fromUri === undefined ? new CodeDisplay() : fromUri;
    }
    return new Code(account, issuer, Code.getDigits(uri), Code.getPeriod(uri),
      getSanitizedSecret(uri.queryParams.get('secret') as string), Code.getAlgorithm(uri),
      Code.getType(uri), Code.getCounter(uri), rawData, undefined, display);
  }

  static fromExportJson(rawJson: object): Code {
    const map: Record<string, Object> = rawJson as Record<string, Object>;
    const display: CodeDisplay = CodeDisplay.fromJsonObject(map['display'] as object);
    return Code.fromOTPAuthUrl(map['rawData'] as string, display);
  }

  toOTPAuthUrlFormat(): string {
    const uri: UriComponent = UriComponent.parse(this.rawData.replaceAll('#', '%23'));
    const query: Map<string, string> = new Map<string, string>();
    uri.queryParams.forEach((v: string, k: string) => {
      query.set(k, v);
    });
    query.set('codeDisplay', JSON.stringify(this.display.toJsonObject()));
    const newUri: string = UriComponent.serialize(uri.scheme, uri.host, uri.pathEncoded, query);
    return JSON.stringify(newUri);
  }

  static getIssuer(uri: UriComponent): string {
    try {
      if (uri.queryParams.has('issuer')) {
        let issuerName: string = uri.queryParams.get('issuer') as string;
        // Handle issuer name with period
        // See https://github.com/ente/ente/pull/77
        if (issuerName.includes('period=')) {
          return issuerName.substring(0, issuerName.indexOf('period='));
        }
        return issuerName;
      }
      const path: string = UriComponent.decodeComponent(uri.pathEncoded);
      return path.split(':')[0].substring(1);
    } catch (e) {
      return '';
    }
  }

  static getAccount(uri: UriComponent, issuer: string): string {
    try {
      let path: string = UriComponent.decodeComponent(uri.pathEncoded);
      if (path.startsWith('/')) {
        path = path.substring(1, path.length);
      }
      if (uri.queryParams.has('issuer') && !path.includes(':')) {
        return path;
      }
      if (path.startsWith(`${issuer}:`)) {
        return path.substring(issuer.length + 1);
      }
      return path.substring(path.indexOf(':') + 1);
    } catch (e) {
      return '';
    }
  }

  static getDigits(uri: UriComponent): number {
    try {
      return strictParseInt(uri.queryParams.get('digits') as string);
    } catch (e) {
      if (uri.host === 'steam') {
        return Code.steamDigits;
      }
      return Code.defaultDigits;
    }
  }

  static getPeriod(uri: UriComponent): number {
    try {
      return strictParseInt(uri.queryParams.get('period') as string);
    } catch (e) {
      return Code.defaultPeriod;
    }
  }

  static getCounter(uri: UriComponent): number {
    try {
      const hasCounterKey: boolean = uri.queryParams.has('counter');
      if (!hasCounterKey) {
        return 0;
      }
      return strictParseInt(uri.queryParams.get('counter') as string);
    } catch (e) {
      return Code.defaultPeriod;
    }
  }

  static getAlgorithm(uri: UriComponent): OtpAlgorithm {
    try {
      const algorithm: string = ((uri.queryParams.get('algorithm') as string) ?? '').toLowerCase();
      if (algorithm === 'sha256' || algorithm === 'algorithm.sha256') {
        return OtpAlgorithm.sha256;
      } else if (algorithm === 'sha512' || algorithm === 'algorithm.sha512') {
        return OtpAlgorithm.sha512;
      }
    } catch (e) {
      // Fall back to SHA-1.
    }
    return OtpAlgorithm.sha1;
  }

  static getType(uri: UriComponent): OtpType {
    if (uri.host === 'totp') {
      return OtpType.totp;
    } else if (uri.host === 'steam') {
      return OtpType.steam;
    } else if (uri.host === 'hotp') {
      return OtpType.hotp;
    }
    throw new Error(`UnsupportedError: Unsupported format with host ${uri.host}`);
  }

  equals(o: Code): boolean {
    if (this === o) {
      return true;
    }
    if (o === undefined || o === null) {
      return false;
    }
    return o.account === this.account && o.issuer === this.issuer &&
      o.digits === this.digits && o.period === this.period &&
      o.secret === this.secret && o.counter === this.counter &&
      o.type === this.type && o.rawData === this.rawData;
  }

  hashCode(): number {
    return this.account.length + this.issuer.length + this.digits + this.period +
      this.secret.length + this.counter + this.type.toString().length + this.rawData.length;
  }
}

/** Secret normalization shared with upstream totp_util.dart. */
export function getSanitizedSecret(secret: string): string {
  return secret.toUpperCase().trim().replaceAll(' ', '');
}

/** Dart int.parse-equivalent: throws unless the string is a plain integer. */
export function strictParseInt(s: string): number {
  if (s === undefined || s === null) {
    throw new Error('FormatException: null');
  }
  if (!/^[+-]?\d+$/.test(s)) {
    throw new Error(`FormatException: Invalid radix-10 number: ${s}`);
  }
  return parseInt(s, 10);
}

/** Base64 (std) encode of UTF-8 bytes of a string. */
export function utf8Bytes(s: string): Uint8Array {
  return Utf8Strict.encode(s);
}