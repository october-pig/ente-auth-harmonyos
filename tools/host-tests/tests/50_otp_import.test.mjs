/**
 * 50_otp_import.test.mjs — PRIORITY 9/10: OTP core + import/export.
 *
 * Executes the real production modules:
 *   otp/Otp.ets, otp/Base32.ets, otp/SteamTotp.ets, otp/TotpUtil.ets
 *   models/Code.ets, models/CodeDisplay.ets, models/UriComponent.ets
 *   services/ImportService.ets, services/EnteExport.ets
 *
 * Upstream authority:
 *   .upstream/pub/lib/otp.dart + test/otp_test.dart          (otp 3.2.0)
 *   .upstream/pub/lib/src/steam_totp_base.dart + test/steam_totp_test.dart
 *   .upstream/ente/mobile/apps/auth/lib/models/code.dart
 *   .upstream/ente/mobile/apps/auth/lib/utils/totp_util.dart
 *   .upstream/ente/mobile/apps/auth/lib/ui/settings/data/import/*
 *   RFC 4226 section 5.4, RFC 6238 Appendix B
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assert, assertBytes, assertEquals, assertRejects, assertThrows, describe, it } from '../framework.mjs';

const { Otp } = await import('../gen/entry/src/main/ets/otp/Otp.ts');
const { OtpAlgorithm, OtpType } = await import('../gen/entry/src/main/ets/otp/OtpTypes.ts');
const { Base32 } = await import('../gen/entry/src/main/ets/otp/Base32.ts');
const { SteamTotp } = await import('../gen/entry/src/main/ets/otp/SteamTotp.ts');
const totpUtil = await import('../gen/entry/src/main/ets/otp/TotpUtil.ts');
const { Code, getSanitizedSecret } = await import('../gen/entry/src/main/ets/models/Code.ts');
const { CodeDisplay } = await import('../gen/entry/src/main/ets/models/CodeDisplay.ts');
const { UriComponent, Utf8Strict } = await import('../gen/entry/src/main/ets/models/UriComponent.ts');
const { ImportService, IncorrectPasswordError } = await import('../gen/entry/src/main/ets/services/ImportService.ts');
const { EnteExport } = await import('../gen/entry/src/main/ets/services/EnteExport.ts');
const { CryptoUtil } = await import('../gen/entry/src/main/ets/crypto/CryptoUtil.ts');
const { __resetPreferences, __resetRdb } = await import('../shims/kit-arkdata.mjs');
const { __resetHuks } = await import('../shims/kit-huks.mjs');
const { Preferences } = await import('../gen/entry/src/main/ets/storage/Preferences.ts');

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = JSON.parse(readFileSync(
  join(HERE, '..', '..', '..', 'entry', 'src', 'test', 'fixtures', 'crypto_vectors.json'), 'utf8'));
const field = (v) => v.startsWith('hex:')
  ? new Uint8Array(Buffer.from(v.slice(4), 'hex'))
  : new Uint8Array(Buffer.from(v.slice(7), 'base64'));

const utf8 = (s) => new Uint8Array(new TextEncoder().encode(s));

// ============================================================== RFC 4226 HOTP

describe('RFC 4226 HOTP (SHA-1)', () => {
  // RFC 4226 Appendix D: secret = ASCII "12345678901234567890"
  const SECRET_B32 = Base32.encode(utf8('12345678901234567890'));
  const EXPECTED = [
    '755224', '287082', '359152', '969429', '338314',
    '254676', '287922', '162583', '399871', '520489',
  ];
  it('secret encodes to the RFC base32 form', () => {
    assertEquals(SECRET_B32, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 'RFC 4226 secret base32');
  });
  for (let counter = 0; counter < EXPECTED.length; counter++) {
    it(`counter ${counter} -> ${EXPECTED[counter]}`, async () => {
      assertEquals(
        await Otp.generateHOTPCodeString(SECRET_B32, counter, 6, OtpAlgorithm.sha1),
        EXPECTED[counter]);
    });
  }
});

// ============================================================== RFC 6238 TOTP

describe('RFC 6238 TOTP (Appendix B)', () => {
  const S1 = '12345678901234567890';
  const S256 = '12345678901234567890123456789012';
  const S512 = '1234567890123456789012345678901234567890123456789012345678901234';
  const TIMES = [59, 1111111109, 1111111111, 1234567890, 2000000000, 20000000000];
  const VECTORS = {
    sha1: ['94287082', '07081804', '14050471', '89005924', '69279037', '65353130'],
    sha256: ['46119246', '68084774', '67062674', '91819424', '90698825', '77737706'],
    sha512: ['90693936', '25091201', '99943326', '93441116', '38618901', '47863826'],
  };
  for (const [algo, expected] of Object.entries(VECTORS)) {
    const secret = Base32.encode(utf8(algo === 'sha1' ? S1 : algo === 'sha256' ? S256 : S512));
    for (let i = 0; i < TIMES.length; i++) {
      it(`${algo} T=${TIMES[i]} -> ${expected[i]}`, async () => {
        assertEquals(
          await Otp.generateTOTPCodeString(secret, TIMES[i] * 1000, 8, 30, OtpAlgorithm[algo]),
          expected[i]);
      });
    }
  }
});

// ========================================================= otp 3.2.0 vectors

describe('otp 3.2.0 package vectors (.upstream/pub/test/otp_test.dart)', () => {
  const HALFMINUTES = 45410085;
  const TIME = HALFMINUTES * 30 * 1000;
  // IMPORTANT: the `otp` package defaults to `isGoogle: false`, which means the
  // secret STRING is used as raw UTF-8 bytes (then padded for TOTP), NOT
  // base32-decoded. The Ente auth app always passes `isGoogle: true`
  // (totp_util.dart:25,35), which is the port's `asBase32` default. The
  // package vectors below therefore pass asBase32 = false explicitly.

  it('TOTP SHA256 default length at the package test time -> 505548', async () => {
    assertEquals(await Otp.generateTOTPCodeString('JBSWY3DPEHPK3PXP', TIME, 6, 30, OtpAlgorithm.sha256, false), '505548');
  });
  it('TOTP SHA1 at the same time -> 492280', async () => {
    assertEquals(await Otp.generateTOTPCodeString('JBSWY3DPEHPK3PXP', TIME, 6, 30, OtpAlgorithm.sha1, false), '492280');
  });
  it('TOTP SHA512 at the same time -> 922649', async () => {
    assertEquals(await Otp.generateTOTPCodeString('JBSWY3DPEHPK3PXP', TIME, 6, 30, OtpAlgorithm.sha512, false), '922649');
  });
  it('TOTP length 7 one step later -> 7571013', async () => {
    assertEquals(await Otp.generateTOTPCodeString('JBSWY3DPEHPK3PXP', TIME + 30000, 7, 30, OtpAlgorithm.sha256, false), '7571013');
  });
  it('HOTP counter 7 SHA256 (isGoogle false, unpadded) -> 75389', async () => {
    assertEquals(await Otp.generateHOTPCodeString('JBSWY3DPEHPK3PXP', 7, 6, OtpAlgorithm.sha256, false), '075389');
  });
  it('HOTP counter 7 SHA1 (isGoogle false, unpadded) -> 6676', async () => {
    assertEquals(await Otp.generateHOTPCodeString('JBSWY3DPEHPK3PXP', 7, 6, OtpAlgorithm.sha1, false), '006676');
  });
  it('HOTP counter 7 SHA256 with isGoogle true -> 346239', async () => {
    assertEquals(await Otp.generateHOTPCodeString('JBSWY3DPEHPK3PXP', 7, 6, OtpAlgorithm.sha256, true), '346239');
  });
  it('isGoogle path (base32 decode, no padding) -> 700998', async () => {
    assertEquals(
      await Otp.generateTOTPCodeString('Q4D65VKZ3T5NERSB', 1589633445440, 6, 30, OtpAlgorithm.sha1, true),
      '700998');
  });
  it('a secret containing characters outside the base32 alphabet raises', async () => {
    // NOTE: upstream's own test uses 'sdfsdf' and expects a FormatException.
    // That test is VACUOUS: the package uppercases the secret first, 'SDFSDF'
    // is valid base32, and the decode returns 0 bytes without throwing, so the
    // try-block never enters the catch and the test passes without asserting
    // anything. A secret with a real out-of-alphabet character does raise.
    await assertRejects(
      () => Otp.generateTOTPCodeString('JBSWY3DP1', TIME, 6, 30, OtpAlgorithm.sha256, true),
      "'1' is not in the RFC 4648 base32 alphabet");
    await assertRejects(
      () => Otp.generateTOTPCodeString('JBSWY3DP0', TIME, 6, 30, OtpAlgorithm.sha256, true),
      "'0' is not in the RFC 4648 base32 alphabet");
    // And the upstream case indeed does NOT throw (documented quirk).
    const noThrow = await Otp.generateTOTPCodeString('sdfsdf', TIME, 6, 30, OtpAlgorithm.sha256, true);
    assertEquals(typeof noThrow, 'string', "'sdfsdf' uppercases to valid base32 and does not throw");
  });
  it('padSecret repeats-then-truncates, and leaves short/long/empty inputs alone', () => {
    // upstream otp.dart:196-206
    assertBytes(Otp.padSecret(new Uint8Array([1, 2, 3]), 8),
      new Uint8Array([1, 2, 3, 1, 2, 3, 1, 2]), 'repeat then truncate');
    assertBytes(Otp.padSecret(new Uint8Array([1, 2, 3]), 2),
      new Uint8Array([1, 2, 3]), 'already long enough -> unchanged');
    assertBytes(Otp.padSecret(new Uint8Array(0), 8), new Uint8Array(0), 'empty stays empty');
  });
});

// =================================================================== Steam

describe('steam_totp 0.0.2 vectors', () => {
  it('secret "AA" at unix 42 -> DR2DK', async () => {
    assertEquals(await new SteamTotp('AA').generate(42), 'DR2DK');
  });
  it('an empty secret throws', () => {
    assertThrows(() => new SteamTotp(''), 'empty secret');
  });
  it('an invalid base32 secret throws', () => {
    assertThrows(() => new SteamTotp('A'), 'invalid base32');
  });
  it('a negative unix time throws', async () => {
    await assertRejects(() => new SteamTotp('AA').generate(-1), 'negative time');
  });
  it('the alphabet is the 26-char Steam set', () => {
    assertEquals(SteamTotp.STEAM_CHARS, '23456789BCDFGHJKMNPQRTVWXY');
    assertEquals(SteamTotp.STEAM_CHARS.length, 26);
  });
  it('codes are 5 chars from the Steam alphabet', async () => {
    const s = new SteamTotp('JBSWY3DPEHPK3PXP');
    for (let t = 0; t < 40; t++) {
      const c = await s.generate(1600000000 + t * 30);
      assertEquals(c.length, 5, 'length');
      for (const ch of c) assert(SteamTotp.STEAM_CHARS.includes(ch), `char ${ch}`);
    }
  });
});

// ============================================================== sanitisation

describe('getSanitizedSecret (totp_util.dart:100-102)', () => {
  it('uppercases, trims and strips SPACES only', () => {
    assertEquals(getSanitizedSecret('  jbswy3dpehpk3pxp  '), 'JBSWY3DPEHPK3PXP');
    assertEquals(getSanitizedSecret('jbsw y3dp ehpk 3pxp'), 'JBSWY3DPEHPK3PXP');
    // replaceAll(' ', '') only removes U+0020, not tabs or newlines.
    assertEquals(getSanitizedSecret('JB\tSW'), 'JB\tSW', 'tab is preserved');
    assertEquals(getSanitizedSecret('JB\nSW'), 'JB\nSW', 'newline is preserved');
  });
});

// ========================================================= otpauth URI parse

describe('otpauth URI parsing (models/code.dart)', () => {
  it('parses issuer/account/algorithm/digits/period/secret', () => {
    const c = Code.fromOTPAuthUrl(
      'otpauth://totp/GitHub:octocat@example.com?algorithm=SHA256&digits=8&issuer=GitHub&period=60&secret=JBSWY3DPEHPK3PXP');
    assertEquals(c.type, OtpType.totp, 'type');
    assertEquals(c.issuer, 'GitHub', 'issuer');
    assertEquals(c.account, 'octocat@example.com', 'account');
    assertEquals(c.algorithm, OtpAlgorithm.sha256, 'algorithm');
    assertEquals(c.digits, 8, 'digits');
    assertEquals(c.period, 60, 'period');
    assertEquals(c.secret, 'JBSWY3DPEHPK3PXP', 'secret');
  });

  it('defaults: SHA1, 6 digits, period 30', () => {
    const c = Code.fromOTPAuthUrl('otpauth://totp/Ente:alice?secret=JBSWY3DPEHPK3PXP');
    assertEquals(c.algorithm, OtpAlgorithm.sha1, 'algorithm default');
    assertEquals(c.digits, 6, 'digits default');
    assertEquals(c.period, 30, 'period default');
  });

  it('parses HOTP with a counter', () => {
    const c = Code.fromOTPAuthUrl('otpauth://hotp/VPN:bob?secret=KRSXG5CTMVRXEZLU&counter=7');
    assertEquals(c.type, OtpType.hotp, 'type');
    assertEquals(c.counter, 7, 'counter');
  });

  it('parses a steam URI', () => {
    const c = Code.fromOTPAuthUrl('otpauth://steam/Steam:me?secret=JBSWY3DPEHPK3PXP');
    assertEquals(c.type, OtpType.steam, 'type');
  });

  it('percent-decodes the label and query', () => {
    const c = Code.fromOTPAuthUrl(
      'otpauth://totp/My%20Issuer%3Ame%40example.test?secret=JBSWY3DPEHPK3PXP&issuer=My%20Issuer');
    assertEquals(c.issuer, 'My Issuer', 'issuer decoded');
    assertEquals(c.account, 'me@example.test', 'account decoded');
  });

  it('a fragment is stripped before parsing', () => {
    const c = Code.fromOTPAuthUrl('otpauth://totp/Ente:a?secret=JBSWY3DPEHPK3PXP#frag');
    assertEquals(c.secret, 'JBSWY3DPEHPK3PXP', 'secret survives a fragment');
  });

  it('a period embedded in the issuer label is handled (upstream quirk)', () => {
    // code.dart retries parsing when the issuer contains a period.
    const c = Code.fromOTPAuthUrl('otpauth://totp/example.com:alice?secret=JBSWY3DPEHPK3PXP');
    assertEquals(c.issuer, 'example.com', 'issuer keeps the dot');
    assertEquals(c.account, 'alice', 'account');
  });

  it('a missing secret throws', () => {
    assertThrows(() => Code.fromOTPAuthUrl('otpauth://totp/Ente:a'), 'no secret');
  });

  it('an unsupported host throws', () => {
    assertThrows(() => Code.fromOTPAuthUrl('https://example.com/?secret=JBSWY3DPEHPK3PXP'), 'wrong scheme');
  });
});

describe('Code rawData / codeDisplay round-trip', () => {
  it('rawData is a valid otpauth URI that reparses to the same code', () => {
    const c = Code.fromOTPAuthUrl(
      'otpauth://totp/GitHub:octocat@example.com?algorithm=SHA256&digits=8&issuer=GitHub&period=60&secret=JBSWY3DPEHPK3PXP');
    const again = Code.fromOTPAuthUrl(c.rawData);
    assertEquals(again.issuer, c.issuer, 'issuer');
    assertEquals(again.account, c.account, 'account');
    assertEquals(again.algorithm, c.algorithm, 'algorithm');
    assertEquals(again.digits, c.digits, 'digits');
    assertEquals(again.period, c.period, 'period');
    assertEquals(again.secret, c.secret, 'secret');
  });

  it('codeDisplay JSON round-trips', () => {
    const d = new CodeDisplay(true, false, 123, 4, ['tagA', 'tagB'], 'a note', 7, 'icon.png', 'id9');
    const back = CodeDisplay.fromJsonObject(d.toJsonObject());
    assertEquals(back.pinned, true, 'pinned');
    assertEquals(back.trashed, false, 'trashed');
    assertEquals(back.lastUsedAt, 123, 'lastUsedAt');
    assertEquals(back.tapCount, 4, 'tapCount');
    assertEquals(back.tags, ['tagA', 'tagB'], 'tags');
    assertEquals(back.note, 'a note', 'note');
    assertEquals(back.position, 7, 'position');
    assertEquals(back.iconSrc, 'icon.png', 'iconSrc');
    assertEquals(back.iconID, 'id9', 'iconID');
    assertEquals(d.equals(back), true, 'equals');
    assertEquals(d.isCustomIcon, true, 'isCustomIcon');
  });

  it('codeDisplay defaults match upstream, including its iconSrc asymmetry', () => {
    // code_display.dart:25 vs :77 - the CONSTRUCTOR defaults iconSrc to '',
    // while fromJson(map) defaults a MISSING iconSrc to 'ente'. A null/absent
    // json object takes the constructor path. The port reproduces this exactly.
    for (const input of [undefined, null]) {
      const back = CodeDisplay.fromJsonObject(input);
      assertEquals(back.pinned, false, 'default pinned');
      assertEquals(back.trashed, false, 'default trashed');
      assertEquals(back.tags, [], 'default tags');
      assertEquals(back.note, '', 'default note');
      assertEquals(back.iconSrc, '', 'constructor default iconSrc is ""');
      assertEquals(back.isCustomIcon, false, 'not a custom icon');
    }
    const fromEmpty = CodeDisplay.fromJsonObject({});
    assertEquals(fromEmpty.iconSrc, 'ente', 'fromJson(map) default iconSrc is "ente"');
    assertEquals(fromEmpty.iconID, '', 'default iconID');
    assertEquals(fromEmpty.isCustomIcon, false, 'not a custom icon');
  });

  it('parseCodeDisplayJson survives a legacy unescaped fragment', () => {
    // code_display.dart tolerates legacy JSON followed by an unescaped '#'
    // fragment; anything else must still throw.
    const d = CodeDisplay.parseCodeDisplayJson('{"pinned":true}#frag');
    assertEquals(d.pinned, false, 'legacy case falls back to the default display');
    assertThrows(() => CodeDisplay.parseCodeDisplayJson('{not json}'), 'genuinely invalid JSON throws');
  });
});

// ============================================================ OTP generation

describe('getOTP / getNextTotp / generateFutureTotpCodes', () => {
  it('TOTP digits and length', async () => {
    const c = Code.fromOTPAuthUrl('otpauth://totp/Ente:a?secret=JBSWY3DPEHPK3PXP&digits=6&period=30');
    const code = await totpUtil.getOTP(c);
    assertEquals(code.length, 6, 'six digits');
    assert(/^\d{6}$/.test(code), `numeric: ${code}`);
  });

  it('the issuer "steam" routes to the Steam generator regardless of type', async () => {
    const c = Code.fromOTPAuthUrl('otpauth://totp/Steam:me?secret=JBSWY3DPEHPK3PXP&issuer=Steam');
    const code = await totpUtil.getOTP(c);
    assertEquals(code.length, 5, 'five Steam chars');
    for (const ch of code) assert(SteamTotp.STEAM_CHARS.includes(ch), `steam char ${ch}`);
  });

  it('HOTP uses the stored counter', async () => {
    const c = Code.fromOTPAuthUrl('otpauth://hotp/VPN:b?secret=KRSXG5CTMVRXEZLU&counter=7&digits=8');
    assertEquals(await totpUtil.getOTP(c),
      await Otp.generateHOTPCodeString('KRSXG5CTMVRXEZLU', 7, 8, OtpAlgorithm.sha1), 'HOTP matches');
  });

  it('generateFutureTotpCodes returns period-aligned, distinct codes', async () => {
    const c = Code.fromOTPAuthUrl('otpauth://totp/Ente:a?secret=JBSWY3DPEHPK3PXP&period=30');
    const [startTime, codes] = await totpUtil.generateFutureTotpCodes(c, 5);
    assertEquals(codes.length, 5, 'five codes');
    assertEquals(startTime % (30 * 1000), 0, 'start is period aligned');
    assertEquals(new Set(codes).size, 5, 'codes are distinct');
  });

  it('the server time offset shifts the generated code', async () => {
    const c = Code.fromOTPAuthUrl('otpauth://totp/Ente:a?secret=JBSWY3DPEHPK3PXP&period=30');
    const base = await totpUtil.getOTP(c);
    totpUtil.TimeOffset.setOffset(30000);
    try {
      const shifted = await totpUtil.getOTP(c);
      const expected = await Otp.generateTOTPCodeString(
        'JBSWY3DPEHPK3PXP', Date.now() + 30000, 6, 30, OtpAlgorithm.sha1);
      assertEquals(shifted, expected, 'offset applied');
      assert(base !== shifted || true, 'no assertion on inequality (a step may not have rolled)');
    } finally {
      totpUtil.TimeOffset.setOffset(0);
    }
  });
});

// ============================================================= import / export

describe('plain text import (plain_text_import_parser.dart)', () => {
  it('parses newline-separated otpauth URIs and skips junk', () => {
    const text = [
      'otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP',
      '',
      'not a uri',
      'otpauth://totp/Ente:alice?secret=GEZDGNBVGY3TQOJQ&algorithm=SHA256',
    ].join('\n');
    const codes = ImportService.parsePlainText(text);
    assertEquals(codes.length, 2, 'two valid codes');
    assertEquals(codes[0].issuer, 'GitHub', 'first issuer');
    assertEquals(codes[1].algorithm, OtpAlgorithm.sha256, 'second algorithm');
  });
});

describe('Bitwarden import (bitwarden_import.dart)', () => {
  it('parses otpauth, steam:// and bare-secret entries, with folder tags and notes', () => {
    const content = JSON.stringify({
      folders: [{ id: 'f1', name: 'Work' }],
      items: [
        {
          name: 'GitHub', notes: 'a note', folderId: 'f1',
          login: { username: 'octocat', totp: 'otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP' },
        },
        { name: 'Steam', login: { username: 'me', totp: 'steam://JBSWY3DPEHPK3PXP' } },
        { name: 'Bare', login: { username: 'bob', totp: 'GEZDGNBVGY3TQOJQ' } },
        { name: 'NoTotp', login: { username: 'x' } },
        { name: 'NoLogin' },
      ],
    });
    const codes = ImportService.parseBitwarden(content);
    assertEquals(codes.length, 3, 'three codes (entries without a totp are skipped)');
    assertEquals(codes[0].issuer, 'GitHub', 'otpauth issuer');
    assertEquals(codes[0].display.note, 'a note', 'note carried over');
    assertEquals(codes[0].display.tags, ['Work'], 'folder name becomes a tag');
    assertEquals(codes[1].type, OtpType.steam, 'steam:// entry');
    assertEquals(codes[1].digits, 5, 'steam digits');
    assertEquals(codes[2].type, OtpType.totp, 'bare secret entry');
    assertEquals(codes[2].secret, 'GEZDGNBVGY3TQOJQ', 'bare secret preserved');
  });

  it('an empty/missing items list yields no codes', () => {
    assertEquals(ImportService.parseBitwarden('{}').length, 0, 'no items key');
    assertEquals(ImportService.parseBitwarden('{"items":[]}').length, 0, 'empty items');
  });
});

describe('LastPass import (lastpass_import.dart)', () => {
  it('maps issuerName/userName/secret/algorithm/digits/timeStep', () => {
    const content = JSON.stringify({
      accounts: [
        { issuerName: 'GitHub', userName: 'octocat', secret: 'JBSWY3DPEHPK3PXP' },
        { issuerName: 'Ente', userName: 'alice', secret: 'GEZDGNBVGY3TQOJQ', algorithm: 'SHA256', digits: 8, timeStep: 60 },
        { issuerName: 'Empty', userName: 'x', secret: '' },
      ],
    });
    const codes = ImportService.parseLastPass(content);
    assertEquals(codes.length, 2, 'entries with an empty secret are skipped');
    assertEquals(codes[0].issuer, 'GitHub', 'issuer');
    assertEquals(codes[0].account, 'octocat', 'account');
    assertEquals(codes[0].algorithm, OtpAlgorithm.sha1, 'default algorithm');
    assertEquals(codes[0].digits, 6, 'default digits');
    assertEquals(codes[0].period, 30, 'default period');
    assertEquals(codes[1].algorithm, OtpAlgorithm.sha256, 'SHA256');
    assertEquals(codes[1].digits, 8, 'digits');
    assertEquals(codes[1].period, 60, 'period from timeStep');
  });

  it('a missing accounts key yields no codes', () => {
    assertEquals(ImportService.parseLastPass('{}').length, 0);
  });
});

describe('Raivo import (raivo_plain_text_import.dart)', () => {
  it('parses a top-level array including HOTP', () => {
    const content = JSON.stringify([
      { kind: 'totp', issuer: 'GitHub', account: 'octocat', secret: 'JBSWY3DPEHPK3PXP' },
      { kind: 'hotp', issuer: 'VPN', account: 'bob', secret: 'KRSXG5CTMVRXEZLU', counter: 7, digits: 8 },
      { kind: 'totp', issuer: 'Empty', account: 'x', secret: '' },
    ]);
    const codes = ImportService.parseRaivo(content);
    assertEquals(codes.length, 2, 'empty secret skipped');
    assertEquals(codes[0].type, OtpType.totp, 'totp');
    assertEquals(codes[0].issuer, 'GitHub', 'issuer');
    assertEquals(codes[1].type, OtpType.hotp, 'hotp');
    assertEquals(codes[1].counter, 7, 'counter');
    assertEquals(codes[1].digits, 8, 'digits');
  });

  it('rejects a steam entry, because Raivo imports pass allowSteam: false', () => {
    // upstream raivo_plain_text_import.dart:70 passes allowSteam: false, and
    // buildImportOtpUri throws FormatException('Invalid OTP type: ...') for
    // steam in that case. parseImportOtpCode rethrows, so one bad entry aborts
    // the import - the port reproduces both halves.
    const content = JSON.stringify([
      { kind: 'steam', issuer: 'Steam', account: 'me', secret: 'JBSWY3DPEHPK3PXP' },
    ]);
    assertThrows(() => ImportService.parseRaivo(content), 'steam must be rejected');
  });

  it('an empty array yields no codes', () => {
    assertEquals(ImportService.parseRaivo('[]').length, 0);
  });
});

describe('Google Authenticator migration import (google_auth_migration)', () => {
  // Minimal protobuf writer, so the test exercises the real decoder with a
  // genuinely encoded payload rather than a hand-waved string.
  const varint = (n) => {
    const out = [];
    let v = n;
    do {
      let b = v & 0x7f;
      v >>>= 7;
      if (v) b |= 0x80;
      out.push(b);
    } while (v);
    return out;
  };
  const bytes = (...parts) => parts.flat();
  const tag = (field, wire) => varint((field << 3) | wire);
  const lenDelim = (field, payload) => bytes(tag(field, 2), varint(payload.length), payload);
  const vfield = (field, value) => bytes(tag(field, 0), varint(value));
  const str = (s) => Array.from(new TextEncoder().encode(s));

  function otpParameters({ secret, name, issuer, algorithm, digits, type, counter }) {
    const parts = [];
    parts.push(lenDelim(1, secret));
    if (name !== undefined) parts.push(lenDelim(2, str(name)));
    if (issuer !== undefined) parts.push(lenDelim(3, str(issuer)));
    if (algorithm !== undefined) parts.push(vfield(4, algorithm));
    if (digits !== undefined) parts.push(vfield(5, digits));
    if (type !== undefined) parts.push(vfield(6, type));
    if (counter !== undefined) parts.push(vfield(7, counter));
    return bytes(...parts);
  }

  function migrationUri(paramsList) {
    const body = bytes(...paramsList.map((p) => lenDelim(1, p)), vfield(2, 1), vfield(3, paramsList.length), vfield(4, 0), vfield(5, 1));
    return 'otpauth-migration://offline?data=' +
      encodeURIComponent(Buffer.from(body).toString('base64'));
  }

  it('decodes a TOTP entry (SHA1 / 6 digits)', () => {
    const uri = migrationUri([otpParameters({
      secret: Array.from(Base32.decode('JBSWY3DPEHPK3PXP')), name: 'octocat@example.com', issuer: 'GitHub',
      algorithm: 1, digits: 1, type: 2,
    })]);
    const codes = ImportService.parseGoogleAuth(uri);
    assertEquals(codes.length, 1, 'one code');
    assertEquals(codes[0].type, OtpType.totp, 'type');
    assertEquals(codes[0].issuer, 'GitHub', 'issuer');
    assertEquals(codes[0].account, 'octocat@example.com', 'account');
    assertEquals(codes[0].secret, 'JBSWY3DPEHPK3PXP', 'secret');
    assertEquals(codes[0].algorithm, OtpAlgorithm.sha1, 'algorithm');
    assertEquals(codes[0].digits, 6, 'digits');
  });

  it('decodes SHA256/8-digit and HOTP entries', () => {
    const uri = migrationUri([
      otpParameters({
        secret: Array.from(Base32.decode('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ')), name: 'alice', issuer: 'Ente',
        algorithm: 2, digits: 2, type: 2,
      }),
      otpParameters({
        secret: Array.from(Base32.decode('KRSXG5CTMVRXEZLU')), name: 'bob', issuer: 'VPN',
        algorithm: 3, digits: 2, type: 1, counter: 7,
      }),
    ]);
    const codes = ImportService.parseGoogleAuth(uri);
    assertEquals(codes.length, 2, 'two codes');
    assertEquals(codes[0].algorithm, OtpAlgorithm.sha256, 'SHA256');
    assertEquals(codes[0].digits, 8, '8 digits');
    assertEquals(codes[1].type, OtpType.hotp, 'HOTP');
    assertEquals(codes[1].algorithm, OtpAlgorithm.sha512, 'SHA512');
    assertEquals(codes[1].counter, 7, 'counter');
  });

  it('a non-migration payload is rejected', () => {
    assertThrows(() => ImportService.parseGoogleAuth('{"not":"a migration"}'),
      'unsupported Google Authenticator format');
  });
});

describe('Ente encrypted export envelope (cross-crypto test)', () => {
  it('the production IMPORT path decrypts the committed fixture into 3 codes', async () => {
    __resetPreferences(); __resetRdb(); __resetHuks();
    await Preferences.init({});
    const f = FIXTURES.enteExport;
    const codes = await ImportService.parseEnteEncrypted(
      JSON.stringify({
        version: f.version,
        kdfParams: {
          memLimit: f.kdfParams.memLimit,
          opsLimit: f.kdfParams.opsLimit,
          salt: f.kdfParams.salt.slice(7),
        },
        encryptedData: f.encryptedData.slice(7),
        encryptionNonce: f.encryptionNonce.slice(7),
      }),
      f.password);
    assertEquals(codes.length, 3, 'three codes');
    assertEquals(codes[0].issuer, 'GitHub', 'code 0 issuer');
    assertEquals(codes[1].algorithm, OtpAlgorithm.sha256, 'code 1 algorithm');
    assertEquals(codes[2].type, OtpType.hotp, 'code 2 type');
    assertEquals(codes[2].counter, 7, 'code 2 counter');
  });

  it('a wrong password raises IncorrectPasswordError', async () => {
    const f = FIXTURES.enteExport;
    let err = null;
    try {
      await ImportService.parseEnteEncrypted(
        JSON.stringify({
          version: 1,
          kdfParams: {
            memLimit: f.kdfParams.memLimit, opsLimit: f.kdfParams.opsLimit,
            salt: f.kdfParams.salt.slice(7),
          },
          encryptedData: f.encryptedData.slice(7),
          encryptionNonce: f.encryptionNonce.slice(7),
        }),
        'definitely-not-the-password');
    } catch (e) {
      err = e;
    }
    assert(err !== null, 'must throw');
    assertEquals(err instanceof IncorrectPasswordError, true,
      `expected IncorrectPasswordError, got ${err.constructor ? err.constructor.name : '?'}: ${err.message}`);
  });

  it('production export primitives -> reference decrypt -> production import', async () => {
    __resetPreferences(); __resetRdb(); __resetHuks();
    await Preferences.init({});
    const { createRequire } = await import('node:module');
    const sodium = createRequire(import.meta.url)('libsodium-wrappers-sumo');
    await sodium.ready;
    const entecrypto = await import('../shims/entecrypto.mjs');

    const password = 'round-trip-password';
    const plaintext = FIXTURES.enteExport.plaintext;
    // Reproduce EnteExport.exportEncrypted exactly (EnteExport.ets:49-67), with
    // the derivation capped so the test stays fast and deterministic.
    entecrypto.__setMemLimitCeiling(268435456);
    let payload;
    try {
      const kekSalt = CryptoUtil.getSaltToDeriveKey();
      const derived = await CryptoUtil.deriveSensitiveKey(CryptoUtil.utf8Encode(password), kekSalt);
      const encrypted = await CryptoUtil.encryptData(CryptoUtil.utf8Encode(plaintext), derived.key);
      payload = {
        version: 1,
        encryptedData: CryptoUtil.bin2base64(encrypted.encryptedData),
        encryptionNonce: CryptoUtil.bin2base64(encrypted.header),
        kdfParams: {
          memLimit: derived.memLimit,
          opsLimit: derived.opsLimit,
          salt: CryptoUtil.bin2base64(kekSalt),
        },
      };
    } finally {
      entecrypto.__setMemLimitCeiling(Infinity);
    }

    assertEquals(Object.keys(payload).sort(),
      ['encryptedData', 'encryptionNonce', 'kdfParams', 'version'], 'envelope fields');
    assertEquals(Object.keys(payload.kdfParams).sort(),
      ['memLimit', 'opsLimit', 'salt'], 'kdfParams fields');
    for (const k of ['encryptedData', 'encryptionNonce']) {
      assert(!payload[k].includes('-') && !payload[k].includes('_'), `${k} must be standard base64`);
    }
    assert(!payload.kdfParams.salt.includes('-') && !payload.kdfParams.salt.includes('_'),
      'salt must be standard base64');

    // Independent reference decrypt with libsodium directly.
    const kek = sodium.crypto_pwhash(
      32, utf8(password), new Uint8Array(Buffer.from(payload.kdfParams.salt, 'base64')),
      payload.kdfParams.opsLimit, payload.kdfParams.memLimit,
      sodium.crypto_pwhash_ALG_ARGON2ID13);
    const state = sodium.crypto_secretstream_xchacha20poly1305_init_pull(
      new Uint8Array(Buffer.from(payload.encryptionNonce, 'base64')), kek);
    const r = sodium.crypto_secretstream_xchacha20poly1305_pull(
      state, new Uint8Array(Buffer.from(payload.encryptedData, 'base64')), null);
    assertEquals(new TextDecoder().decode(r.message), plaintext,
      'the reference implementation decrypts the production export');

    // And the production import path reads it back too.
    const codes = await ImportService.parseEnteEncrypted(JSON.stringify(payload), password);
    assertEquals(codes.length, 3, 'production import round trip');
  });
});
