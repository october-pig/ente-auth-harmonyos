/**
 * Minimal Dart-`Uri`-compatible parsing/encoding helpers, mirroring the exact
 * semantics of `dart:core` Uri as used by upstream Ente Auth
 * (`ente@3cc9103a3126de07f79a4465cf0b9922903de54b`, models/code.dart):
 *
 *  - queryParameters: split '&', first '=' per part, percent-decode with
 *    '+' → space (decodeQueryComponent), strict UTF-8; keys without '='
 *    map to "".
 *  - decodeComponent: percent-decode, '+' literal, strict UTF-8.
 *  - encodeQueryComponent: percent-encode everything except unreserved
 *    [A-Za-z0-9-._~], space → '+'.
 *  - host is normalized to lowercase; '#' starts the fragment (stripped).
 *
 * Errors: any malformed percent/UTF-8 input throws Error (Dart throws
 * ArgumentError/FormatException; callers treat them uniformly).
 */
export class UriComponent {
  readonly scheme: string;
  readonly host: string;
  readonly pathEncoded: string;
  readonly queryRaw: string;
  readonly queryParams: Map<string, string>;

  private constructor(scheme: string, host: string, pathEncoded: string,
    queryRaw: string, queryParams: Map<string, string>) {
    this.scheme = scheme;
    this.host = host;
    this.pathEncoded = pathEncoded;
    this.queryRaw = queryRaw;
    this.queryParams = queryParams;
  }

  /** Parses an otpauth-style URI (`scheme://host/path?query`). */
  static parse(raw: string): UriComponent {
    let s: string = raw;
    // Fragment: everything after the first '#' is a fragment in Dart's Uri.
    const hashIdx: number = s.indexOf('#');
    if (hashIdx !== -1) {
      s = s.substring(0, hashIdx);
    }
    let scheme: string = '';
    let rest: string = s;
    const schemeIdx: number = s.indexOf('://');
    if (schemeIdx !== -1) {
      scheme = s.substring(0, schemeIdx);
      rest = s.substring(schemeIdx + 3);
    }
    const slashIdx: number = rest.indexOf('/');
    const qIdx: number = rest.indexOf('?');
    let host: string = '';
    let pathEncoded: string = '';
    let queryRaw: string = '';
    if (slashIdx === -1 && qIdx === -1) {
      host = rest;
    } else if (slashIdx === -1) {
      host = rest.substring(0, qIdx);
      queryRaw = rest.substring(qIdx + 1);
    } else if (qIdx === -1 || slashIdx < qIdx) {
      host = rest.substring(0, slashIdx);
      let afterHost: string = rest.substring(slashIdx);
      const qq: number = afterHost.indexOf('?');
      if (qq !== -1) {
        pathEncoded = afterHost.substring(0, qq);
        queryRaw = afterHost.substring(qq + 1);
      } else {
        pathEncoded = afterHost;
      }
    } else {
      host = rest.substring(0, qIdx);
      queryRaw = rest.substring(qIdx + 1);
    }
    if (scheme.length === 0 && host.length === 0) {
      throw new Error('FormatException: Invalid URI');
    }
    return new UriComponent(scheme, host.toLowerCase(), UriComponent.normalizePath(pathEncoded),
      queryRaw, UriComponent.parseQuery(queryRaw));
  }

  private static normalizePath(p: string): string {
    // Dart Uri treats an empty path as '/'; keep as given otherwise.
    return p;
  }

  private static parseQuery(queryRaw: string): Map<string, string> {
    const map: Map<string, string> = new Map<string, string>();
    if (queryRaw.length === 0) {
      return map;
    }
    const parts: string[] = queryRaw.split('&');
    for (let i = 0; i < parts.length; i++) {
      const element: string = parts[i];
      const index: number = element.indexOf('=');
      if (index === -1) {
        if (element !== '') {
          map.set(UriComponent.decodeQueryComponent(element), '');
        }
      } else if (index !== 0) {
        const key: string = element.substring(0, index);
        const value: string = element.substring(index + 1);
        map.set(UriComponent.decodeQueryComponent(key), UriComponent.decodeQueryComponent(value));
      }
    }
    return map;
  }

  /** decodeQueryComponent: percent-decode with '+' → space, strict UTF-8. */
  static decodeQueryComponent(component: string): string {
    return UriComponent.uriDecode(component, true);
  }

  /** decodeComponent: percent-decode, '+' stays '+', strict UTF-8. */
  static decodeComponent(encodedComponent: string): string {
    return UriComponent.uriDecode(encodedComponent, false);
  }

  /**
   * encodeQueryComponent: percent-encode everything except unreserved
   * [A-Za-z0-9-._~]; space → '+'.
   */
  static encodeQueryComponent(component: string): string {
    let out: string = '';
    for (let i = 0; i < component.length; i++) {
      const c: string = component.charAt(i);
      const code: number = component.charCodeAt(i);
      const u: boolean = (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A) ||
        (code >= 0x30 && code <= 0x39);
      if (u || c === '-' || c === '.' || c === '_' || c === '~') {
        out = out + c;
      } else if (code === 0x20) {
        out = out + '+';
      } else {
        out = out + UriComponent.percentEncodeUtf8(component, i);
      }
    }
    return out;
  }

  /** Serializes like Dart's Uri.toString() for otpauth URIs with query params. */
  static serialize(scheme: string, host: string, pathEncoded: string,
    queryParams: Map<string, string>): string {
    let out: string = scheme + '://' + host;
    if (pathEncoded.length > 0) {
      out = out + pathEncoded;
    }
    if (queryParams.size > 0) {
      out = out + '?';
      let first: boolean = true;
      queryParams.forEach((v: string, k: string) => {
        if (!first) {
          out = out + '&';
        }
        first = false;
        out = out + UriComponent.encodeQueryComponent(k) + '=' + UriComponent.encodeQueryComponent(v);
      });
    }
    return out;
  }

  private static uriDecode(text: string, plusToSpace: boolean): string {
    let simple: boolean = true;
    for (let i = 0; i < text.length; i++) {
      const codeUnit: number = text.charCodeAt(i);
      if (codeUnit > 127 || codeUnit === 0x25 || (plusToSpace && codeUnit === 0x2B)) {
        simple = false;
        break;
      }
    }
    if (simple) {
      return text;
    }
    const bytes: number[] = [];
    for (let i = 0; i < text.length; i++) {
      const codeUnit: number = text.charCodeAt(i);
      if (codeUnit > 127) {
        throw new Error('ArgumentError: Illegal percent encoding in URI');
      }
      if (codeUnit === 0x25) { // '%'
        if (i + 3 > text.length) {
          throw new Error('ArgumentError: Truncated URI');
        }
        bytes.push(UriComponent.hexCharPairToByte(text, i + 1));
        i += 2;
      } else if (plusToSpace && codeUnit === 0x2B) { // '+'
        bytes.push(0x20);
      } else {
        bytes.push(codeUnit);
      }
    }
    return Utf8Strict.decode(bytes);
  }

  private static hexCharPairToByte(s: string, pos: number): number {
    let byte: number = 0;
    for (let i = 0; i < 2; i++) {
      let charCode: number = s.charCodeAt(pos + i);
      if (0x30 <= charCode && charCode <= 0x39) {
        byte = byte * 16 + charCode - 0x30;
      } else {
        charCode = charCode | 0x20;
        if (0x61 <= charCode && charCode <= 0x66) {
          byte = byte * 16 + charCode - 0x57;
        } else {
          throw new Error('ArgumentError: Invalid URL encoding');
        }
      }
    }
    return byte;
  }

  /** Percent-encodes the UTF-8 bytes of the char at index i, including all continuation bytes. */
  private static percentEncodeUtf8(component: string, i: number): string {
    const utf8: Uint8Array = Utf8Strict.encodeCharAt(component, i);
    let out: string = '';
    for (let b = 0; b < utf8.length; b++) {
      const v: number = utf8[b];
      const hex: string = v.toString(16).toUpperCase();
      out = out + '%' + (hex.length === 1 ? '0' + hex : hex);
    }
    return out;
  }
}

/** Strict UTF-8 codec with Dart-compatible error behavior. */
export class Utf8Strict {
  /** UTF-8 encodes a whole string. */
  static encode(s: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < s.length; i++) {
      let code: number = s.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length) {
        const low: number = s.charCodeAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
          i++;
        }
      }
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
      } else if (code < 0x10000) {
        out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      } else {
        out.push(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F),
          0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      }
    }
    return Uint8Array.from(out);
  }

  /** UTF-8 encodes the (possibly surrogate-paired) character starting at index i; advances via return. */
  static encodeCharAt(s: string, i: number): Uint8Array {
    let code: number = s.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length) {
      const low: number = s.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
      }
    }
    let bytes: number[];
    if (code < 0x80) {
      bytes = [code];
    } else if (code < 0x800) {
      bytes = [0xC0 | (code >> 6), 0x80 | (code & 0x3F)];
    } else if (code < 0x10000) {
      bytes = [0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F)];
    } else {
      bytes = [0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F),
        0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F)];
    }
    const arr: Uint8Array = Uint8Array.from(bytes);
    return arr;
  }

  /** Strict UTF-8 decode; throws Error (Dart FormatException 'Invalid UTF-8') on malformed input. */
  static decode(bytesArr: number[]): string {
    const bytes: Uint8Array = Uint8Array.from(bytesArr);
    let out: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      const b0: number = bytes[i];
      if (b0 < 0x80) {
        out = out + String.fromCharCode(b0);
        i++;
      } else if ((b0 & 0xE0) === 0xC0) {
        if (i + 1 >= bytes.length) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        const b1: number = bytes[i + 1];
        if ((b1 & 0xC0) !== 0x80) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        const cp: number = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
        if (cp < 0x80) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        out = out + String.fromCharCode(cp);
        i += 2;
      } else if ((b0 & 0xF0) === 0xE0) {
        if (i + 2 >= bytes.length) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        const b1: number = bytes[i + 1];
        const b2: number = bytes[i + 2];
        if ((b1 & 0xC0) !== 0x80 || (b2 & 0xC0) !== 0x80) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        const cp: number = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
        if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF)) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        out = out + String.fromCharCode(cp);
        i += 3;
      } else if ((b0 & 0xF8) === 0xF0) {
        if (i + 3 >= bytes.length) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        const b1: number = bytes[i + 1];
        const b2: number = bytes[i + 2];
        const b3: number = bytes[i + 3];
        if ((b1 & 0xC0) !== 0x80 || (b2 & 0xC0) !== 0x80 || (b3 & 0xC0) !== 0x80) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        const cp: number = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
        if (cp < 0x10000 || cp > 0x10FFFF) {
          throw new Error('FormatException: Invalid UTF-8');
        }
        const adjusted: number = cp - 0x10000;
        out = out + String.fromCharCode(0xD800 + (adjusted >> 10), 0xDC00 + (adjusted & 0x3FF));
        i += 4;
      } else {
        throw new Error('FormatException: Invalid UTF-8');
      }
    }
    return out;
  }
}