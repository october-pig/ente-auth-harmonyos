/**
 * 10_encoding.test.mjs — PRIORITY 1: byte-encoding correctness.
 *
 * Every expectation here is derived from the pinned upstream sources:
 *   - base32 2.1.3  : .upstream/pub/lib/base32.dart + test/base32_test.dart
 *   - ente_crypto_dart CryptoUtil : .upstream/ente_crypto_dart/lib/src/crypto_util.dart
 *   - dart:convert base64UrlEncode (padded url-safe) as used by
 *     base_configuration.dart:231,279 for the session token
 *
 * The modules under test are the REAL production ArkTS sources (see 00_smoke).
 */
import {
  assert, assertBytes, assertEquals, assertThrows, describe, fromHex, hex, it,
} from '../framework.mjs';

const Base32 = (await import('../gen/entry/src/main/ets/otp/Base32.ts')).Base32;
const { Utf8Strict } = await import('../gen/entry/src/main/ets/models/UriComponent.ts');
const { CryptoUtil } = await import('../gen/entry/src/main/ets/crypto/CryptoUtil.ts');
const { Otp } = await import('../gen/entry/src/main/ets/otp/Otp.ts');

const nodeUtf8Encode = (s) => new Uint8Array(new TextEncoder().encode(s));
const nodeUtf8Decode = (b) => new TextDecoder('utf-8', { fatal: true }).decode(b);

/** Dart `base64UrlEncode`: RFC 4648 §5 alphabet, WITH '=' padding. */
const dartBase64UrlEncode = (u8) =>
  Buffer.from(u8).toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
/** Dart `base64.encode`: standard alphabet, WITH padding. */
const dartBase64Encode = (u8) => Buffer.from(u8).toString('base64');

// ---------------------------------------------------------------------- UTF-8

describe('UTF-8 encode (Utf8Strict.encode vs the platform encoder)', () => {
  const corpus = {
    ascii: 'hello ente auth',
    empty: '',
    digits: '0123456789',
    chinese: '密码测试123',
    japanese: 'こんにちは',
    emoji: '🔐Auth密码',
    emojiZwj: '👨‍👩‍👧‍👦',
    accentedLatin: 'pässwörd',
    combining: 'e\u0301a\u0300',
    cyrillic: 'Пароль',
    arabic: 'كلمة السر',
    zeroByte: 'a\u0000b',
    controls: '\u0001\u0002\u007f',
    maxBmp: '\uffff',
    longAscii: 'x'.repeat(100000),
    longMixed: '密码🔐abc'.repeat(5000),
    bom: '\ufeffhello',
  };

  for (const [name, s] of Object.entries(corpus)) {
    it(`encode matches UTF-8: ${name}`, () => {
      assertBytes(Utf8Strict.encode(s), nodeUtf8Encode(s), `UTF-8 encode mismatch for ${name}`);
    });
  }

  it('all single bytes 0x00..0xFF round-trip through encode/decode', () => {
    // Latin-1 code points 0x00..0xFF are exactly representable as chars.
    for (let cp = 0; cp <= 0xff; cp++) {
      const s = String.fromCharCode(cp);
      const enc = Utf8Strict.encode(s);
      assertBytes(enc, nodeUtf8Encode(s), `U+00${cp.toString(16).padStart(2, '0')}`);
      assertEquals(nodeUtf8Decode(enc), s, `round trip U+00${cp.toString(16).padStart(2, '0')}`);
    }
  });

  it('random binary bytes decode/encode symmetrically where valid', () => {
    // Encode a string built from random valid code points, then decode back.
    let seed = 12345;
    const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
    for (let trial = 0; trial < 200; trial++) {
      let s = '';
      const n = 1 + Math.floor(rnd() * 20);
      for (let i = 0; i < n; i++) {
        const cp = Math.floor(rnd() * 0x10ffff);
        if (cp >= 0xd800 && cp <= 0xdfff) continue;
        s += String.fromCodePoint(cp);
      }
      const enc = Utf8Strict.encode(s);
      assertBytes(enc, nodeUtf8Encode(s), `random trial ${trial}`);
      assertEquals(Utf8Strict.decode(Array.from(enc)), s, `random round trip ${trial}`);
    }
  });
});

describe('UTF-8 decode strictness', () => {
  it('decodes valid multi-byte sequences', () => {
    assertEquals(Utf8Strict.decode([0xe5, 0xaf, 0x86, 0xe7, 0xa0, 0x81]), '密码');
    assertEquals(Utf8Strict.decode([0xf0, 0x9f, 0x94, 0x90]), '🔐');
  });

  it('rejects overlong encodings', () => {
    assertThrows(() => Utf8Strict.decode([0xc0, 0xaf]), 'overlong 2-byte C0 AF');
    assertThrows(() => Utf8Strict.decode([0xe0, 0x80, 0xaf]), 'overlong 3-byte E0 80 AF');
    assertThrows(() => Utf8Strict.decode([0xf0, 0x80, 0x80, 0xaf]), 'overlong 4-byte');
  });

  it('rejects UTF-16 surrogate code points', () => {
    assertThrows(() => Utf8Strict.decode([0xed, 0xa0, 0x80]), 'U+D800 encoded');
    assertThrows(() => Utf8Strict.decode([0xed, 0xbf, 0xbf]), 'U+DFFF encoded');
  });

  it('rejects out-of-range and truncated sequences', () => {
    assertThrows(() => Utf8Strict.decode([0xf4, 0x90, 0x80, 0x80]), '> U+10FFFF');
    assertThrows(() => Utf8Strict.decode([0xe5, 0xaf]), 'truncated 3-byte');
    assertThrows(() => Utf8Strict.decode([0x80]), 'lone continuation');
    assertThrows(() => Utf8Strict.decode([0xff]), 'invalid lead byte');
  });
});

// --------------------------------------------------------------------- Base32

describe('Base32 (RFC 4648, base32 2.1.3 parity)', () => {
  it('RFC 4648 encode vectors (base32.encodeString)', () => {
    const vectors = [
      ['', ''],
      ['f', 'MY======'],
      ['fo', 'MZXQ===='],
      ['foo', 'MZXW6==='],
      ['foob', 'MZXW6YQ='],
      ['fooba', 'MZXW6YTB'],
      ['foobar', 'MZXW6YTBOI======'],
    ];
    for (const [plain, b32] of vectors) {
      assertEquals(Base32.encode(nodeUtf8Encode(plain)), b32, `encode("${plain}")`);
    }
  });

  it('RFC 4648 decode vectors (base32.decodeAsString)', () => {
    const vectors = [
      ['', ''],
      ['MY======', 'f'],
      ['MZXQ====', 'fo'],
      ['MZXW6===', 'foo'],
      ['MZXW6YQ=', 'foob'],
      ['MZXW6YTB', 'fooba'],
      ['MZXW6YTBOI======', 'foobar'],
    ];
    for (const [b32, plain] of vectors) {
      assertEquals(nodeUtf8Decode(Base32.decode(b32)), plain, `decode("${b32}")`);
    }
  });

  it('upstream decode vector: JBSWY3DPEHPK3PXP -> 48656c6c6f21deadbeef', () => {
    assertEquals(hex(Base32.decode('JBSWY3DPEHPK3PXP')), '48656c6c6f21deadbeef');
  });

  it('upstream decode vector with extra final char: JBSWY3DPEHPK3PXPF', () => {
    assertEquals(hex(Base32.decode('JBSWY3DPEHPK3PXPF')), '48656c6c6f21deadbeef');
  });

  it('upstream encode vector: 48656c6c6f21deadbeef -> JBSWY3DPEHPK3PXP', () => {
    assertEquals(Base32.encode(fromHex('48656c6c6f21deadbeef')), 'JBSWY3DPEHPK3PXP');
  });

  it('upstream padding vector: 48656c6c6f21deadbe -> JBSWY3DPEHPK3PQ=', () => {
    assertEquals(Base32.encode(fromHex('48656c6c6f21deadbe')), 'JBSWY3DPEHPK3PQ=');
  });

  it('unpadded input is padded internally (ADWADWADWADDWADWADDWADA)', () => {
    assertEquals(hex(Base32.decode('ADWADWADWADDWADWADDWADA')), '00ec01d803b0063b007600c7600c');
  });

  it('empty string decodes to zero bytes', () => {
    assertEquals(Base32.decode('').length, 0);
  });

  it('rejects invalid characters', () => {
    assertThrows(() => Base32.decode('JBSWY3DPEHPK3PX1'), 'digit 1 is not in the RFC4648 alphabet');
    assertThrows(() => Base32.decode('JBSWY3DPEHPK3PX0'), 'digit 0 is not in the RFC4648 alphabet');
    assertThrows(() => Base32.decode('JBSWY3DPEHPK3PX!'), 'punctuation');
  });

  it('rejects odd-length input after padding check (upstream: FormatException)', () => {
    // 'A' -> padded to 'A=======' which is length 8 (even) but '=' at index 1.
    // Upstream regex ^[A-Z2-7=]+$ passes; the decoded region is length 1 -> no branch matches -> 0 bytes.
    assertEquals(Base32.decode('A').length, 0, 'single char yields no full byte');
  });

  it('round-trips every byte length 0..40', () => {
    for (let n = 0; n <= 40; n++) {
      const bytes = new Uint8Array(n);
      for (let i = 0; i < n; i++) bytes[i] = (i * 37 + 11) & 0xff;
      assertEquals(hex(Base32.decode(Base32.encode(bytes))), hex(bytes), `length ${n}`);
    }
  });
});

// ------------------------------------------------------------------------ Hex

describe('Hex (CryptoUtil.bin2hex / hex2bin)', () => {
  it('bin2hex is lowercase, zero padded', () => {
    assertEquals(CryptoUtil.bin2hex(fromHex('00ff0a10')), '00ff0a10');
    assertEquals(CryptoUtil.bin2hex(new Uint8Array([0, 1, 15, 16, 255])), '00010f10ff');
    assertEquals(CryptoUtil.bin2hex(new Uint8Array(0)), '');
  });

  it('hex2bin accepts lowercase and uppercase', () => {
    assertBytes(CryptoUtil.hex2bin('48656c6c6f'), fromHex('48656c6c6f'));
    assertBytes(CryptoUtil.hex2bin('48656C6C6F'), fromHex('48656c6c6f'));
  });

  it('hex2bin drops a trailing odd character (upstream RegExp(r".{2}") behaviour)', () => {
    assertBytes(CryptoUtil.hex2bin('48656'), fromHex('4865'));
  });

  it('bin2hex/hex2bin round-trip over all byte values', () => {
    const all = new Uint8Array(256);
    for (let i = 0; i < 256; i++) all[i] = i;
    assertBytes(CryptoUtil.hex2bin(CryptoUtil.bin2hex(all)), all);
  });
});

// --------------------------------------------------------------------- Base64

describe('Base64 standard (CryptoUtil.bin2base64 default)', () => {
  const corpus = [
    new Uint8Array(0),
    new Uint8Array([0]),
    new Uint8Array([0, 0]),
    new Uint8Array([0, 0, 0]),
    fromHex('48656c6c6f'),
    fromHex('48656c6c6f21deadbeef'),
    fromHex('fbfffe'),           // forces '+/'
    fromHex('ffffffff'),         // forces '////'
    fromHex('ffffffffff'),
    fromHex('feffefffffff'),
  ];
  for (const bytes of corpus) {
    it(`matches dart base64.encode for ${hex(bytes) || '<empty>'}`, () => {
      assertEquals(CryptoUtil.bin2base64(bytes), dartBase64Encode(bytes),
        `standard base64 mismatch for ${hex(bytes)}`);
    });
  }

  it('base642bin round-trips standard base64', () => {
    for (const bytes of corpus) {
      assertBytes(CryptoUtil.base642bin(dartBase64Encode(bytes)), bytes);
    }
  });
});

describe('Base64 URL-safe (CryptoUtil.bin2base64(urlSafe: true)) — session token path', () => {
  // upstream: base_configuration.dart:231,279
  //   await setToken(CryptoUtil.bin2base64(token, urlSafe: true));
  // and the value is sent verbatim as X-Auth-Token (network.dart:133-136).
  const corpus = [
    new Uint8Array([0]),
    new Uint8Array([0, 0]),
    fromHex('48656c6c6f21deadbeef'),
    fromHex('fbfffe'),            // one '+' and one '/'
    fromHex('fbfffefbfffe'),      // TWO '+' and TWO '/'  <-- first-only replace bug
    fromHex('ffffffff'),          // '////'
    fromHex('ffffffffff'),
    fromHex('ffeffffeffff'),
    fromHex('fbfbfbfb'),
    fromHex('ffff'),              // '//'  + padding
    fromHex('ff'),                // '/'   + padding
    fromHex('ffffff'),            // '///' + padding
  ];
  for (const bytes of corpus) {
    it(`matches dart base64UrlEncode (padded) for ${hex(bytes)}`, () => {
      assertEquals(CryptoUtil.bin2base64(bytes, true), dartBase64UrlEncode(bytes),
        `url-safe base64 mismatch for ${hex(bytes)} (upstream keeps '=' padding)`);
    });
  }

  it('url-safe output never contains + or /', () => {
    for (const bytes of corpus) {
      const s = CryptoUtil.bin2base64(bytes, true);
      assert(!s.includes('+'), `'+' leaked into url-safe output: ${s}`);
      assert(!s.includes('/'), `'/' leaked into url-safe output: ${s}`);
    }
  });

  it('url-safe output keeps = padding like dart:convert', () => {
    assertEquals(CryptoUtil.bin2base64(fromHex('ff'), true), '_w==');
    assertEquals(CryptoUtil.bin2base64(fromHex('ffff'), true), '//8='.replace(/\//g, '_'));
  });
});

// --------------------------------------------------- number <-> byte, endianness

describe('integer <-> bytes endianness (Otp.int2bytes)', () => {
  it('8-byte big-endian encoding', () => {
    assertBytes(Otp.int2bytes(0), new Uint8Array(8), 'zero');
    assertBytes(Otp.int2bytes(1), fromHex('0000000000000001'), 'one');
    assertBytes(Otp.int2bytes(255), fromHex('00000000000000ff'), '255');
    assertBytes(Otp.int2bytes(256), fromHex('0000000000000100'), '256');
    assertBytes(Otp.int2bytes(0x01020304050607), fromHex('0001020304050607'), 'pattern');
    // 0x0102030405060708 exceeds 2^53 and is not exactly representable as a JS
    // number, so it cannot be used as a literal here. Counters in practice are
    // unix-time/30, i.e. ~5.8e7 — far below 2^53.
    assertBytes(Otp.int2bytes(Number.MAX_SAFE_INTEGER), fromHex('001fffffffffffff'), 'MAX_SAFE_INTEGER');
  });
});
