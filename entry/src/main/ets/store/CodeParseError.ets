/**
 * CodeParseError — mirror of upstream `models/code_parse_error.dart`.
 */
export class CodeParseError {
  readonly error: string;
  readonly storedRawData: string;

  constructor(error: string, storedRawData: string) {
    this.error = error;
    this.storedRawData = storedRawData;
  }

  static from(errorObj: Error, storedRawData: string): CodeParseError {
    return new CodeParseError(errorObj.message, storedRawData);
  }

  toString(): string {
    const message = this.error;
    if (this.storedRawData.startsWith('otpauth://')) {
      if (message.includes('Unsupported format with host')) {
        const hostMatch = /Unsupported format with host (\S+)/.exec(message);
        return hostMatch === null ? 'Unsupported OTP type: unknown' : `Unsupported OTP type: ${hostMatch[1]}`;
      }
      if (message.includes('secret') || message.includes('Null') || message.includes('undefined') ||
        message.includes('null')) {
        return 'OTP URL is missing a secret';
      }
      return 'OTP URL is malformed';
    }
    if (message.includes('rawData')) {
      return 'Stored code export is missing rawData';
    }
    return 'Stored code data is not an OTP URL';
  }
}