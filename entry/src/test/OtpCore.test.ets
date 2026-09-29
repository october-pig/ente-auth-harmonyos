import { describe, it, expect } from '@ohos/hypium';
import { Base32 } from '../main/ets/otp/Base32';
import { Otp } from '../main/ets/otp/Otp';
import { OtpAlgorithm, OtpType } from '../main/ets/otp/OtpTypes';
import { SteamTotp } from '../main/ets/otp/SteamTotp';
import { Code, getSanitizedSecret } from '../main/ets/models/Code';
import { UriComponent } from '../main/ets/models/UriComponent';

function hex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    const h = bytes[i].toString(16);
    out = out + (h.length === 1 ? '0' + h : h);
  }
  return out;
}

export default function otpCoreTest() {
  describe('Base32', () => {
    it('RFC4648 JBSWY3DPEHPK3PXP -> Hello!deadbeef', 0, () => {
      const decoded = Base32.decode('JBSWY3DPEHPK3PXP');
      expect(hex(decoded)).assertEqual('48656c6c6f21deadbeef');
    });
    it('RFC4648 JBSWY3DPEHPK3PXPF -> same bytes (18 chars)', 0, () => {
      const decoded = Base32.decode('JBSWY3DPEHPK3PXPF');
      expect(hex(decoded)).assertEqual('48656c6c6f21deadbeef');
    });
    it('encode roundtrip', 0, () => {
      const bytes = Uint8Array.from([0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x21, 0xde, 0xad, 0xbe, 0xef]);
      expect(Base32.encode(bytes)).assertEqual('JBSWY3DPEHPK3PXP');
    });
    it('invalid characters throw', 0, () => {
      try {
        Base32.decode('sdfsdf');
        expect(true).assertFalse();
      } catch (e) {
        expect((e as Error).message).assertEqual('Invalid Base32 characters');
      }
    });
    it('odd length throws (steam_totp "A")', 0, () => {
      try {
        Base32.decode('A');
        expect(true).assertFalse();
      } catch (e) {
        expect(true).assertTrue();
      }
    });
    it('empty decodes to empty', 0, () => {
      expect(Base32.decode('').length).assertEqual(0);
    });
    it('padded input accepted', 0, () => {
      const decoded = Base32.decode('JBSWY3DPEHPK3PXP====');
      expect(hex(decoded)).assertEqual('48656c6c6f21deadbeef');
    });
  });

  describe('RFC 4226 HOTP (raw secret, otp-package path)', () => {
    const tokens = ['755224', '287082', '359152', '969429', '338314', '254676', '287922', '162583', '399871', '520489'];
    it('counter 0..9', 0, async () => {
      for (let i = 0; i < tokens.length; i++) {
        const code = await Otp.generateHOTPCodeString('12345678901234567890', i, 6, OtpAlgorithm.sha1, false);
        expect(code).assertEqual(tokens[i]);
      }
    });
  });

  describe('RFC 6238 TOTP (raw secret, otp-package dataset)', () => {
    // [epoch, token, algorithm] — otp 3.2.0 test dataset (secret 12345678901234567890, digits 8)
    const dataset: [number, string, OtpAlgorithm][] = [
      [59, '94287082', OtpAlgorithm.sha1],
      [59, '46119246', OtpAlgorithm.sha256],
      [59, '90693936', OtpAlgorithm.sha512],
      [1111111109, '07081804', OtpAlgorithm.sha1],
      [1111111109, '68084774', OtpAlgorithm.sha256],
      [1111111109, '25091201', OtpAlgorithm.sha512],
      [1111111111, '14050471', OtpAlgorithm.sha1],
      [1111111111, '67062674', OtpAlgorithm.sha256],
      [1111111111, '99943326', OtpAlgorithm.sha512],
      [1234567890, '89005924', OtpAlgorithm.sha1],
      [1234567890, '91819424', OtpAlgorithm.sha256],
      [1234567890, '93441116', OtpAlgorithm.sha512],
      [2000000000, '69279037', OtpAlgorithm.sha1],
      [2000000000, '90698825', OtpAlgorithm.sha256],
      [2000000000, '38618901', OtpAlgorithm.sha512],
      [20000000000, '65353130', OtpAlgorithm.sha1],
      [20000000000, '77737706', OtpAlgorithm.sha256],
      [20000000000, '47863826', OtpAlgorithm.sha512],
    ];
    it('full dataset, digits 8', 0, async () => {
      for (let i = 0; i < dataset.length; i++) {
        const row = dataset[i];
        const code = await Otp.generateTOTPCodeString('12345678901234567890', row[0] * 1000, 8, 30, row[2], false);
        expect(code).assertEqual(row[1]);
      }
    });
  });

  describe('otp 3.2.0 package vectors', () => {
    it('TOTP JBSWY3DPEHPK3PXP @2013-03-03 09:22:30 UTC SHA1 = 492280', 0, async () => {
      const time = 45410085 * 30 * 1000;
      const code = await Otp.generateTOTPCodeString('JBSWY3DPEHPK3PXP', time, 6, 30, OtpAlgorithm.sha1, false);
      expect(code).assertEqual('492280');
    });
    it('TOTP SHA256 = 505548, SHA512 = 922649', 0, async () => {
      const time = 45410085 * 30 * 1000;
      const c256 = await Otp.generateTOTPCodeString('JBSWY3DPEHPK3PXP', time, 6, 30, OtpAlgorithm.sha256, false);
      const c512 = await Otp.generateTOTPCodeString('JBSWY3DPEHPK3PXP', time, 6, 30, OtpAlgorithm.sha512, false);
      expect(c256).assertEqual('505548');
      expect(c512).assertEqual('922649');
    });
    it('TOTP length 7', 0, async () => {
      const time = 45410085 * 30 * 1000 + 30000;
      const code = await Otp.generateTOTPCodeString('JBSWY3DPEHPK3PXP', time, 7, 30, OtpAlgorithm.sha1, false);
      expect(code).assertEqual('7571013');
    });
    it('HOTP counter 7 SHA1 = 6676, SHA256 = 75389', 0, async () => {
      const a = await Otp.generateHOTPCodeString('JBSWY3DPEHPK3PXP', 7, 6, OtpAlgorithm.sha1, false);
      const b = await Otp.generateHOTPCodeString('JBSWY3DPEHPK3PXP', 7, 6, OtpAlgorithm.sha256, false);
      expect(a).assertEqual('6676');
      expect(b).assertEqual('75389');
    });
    it('base32 (isGoogle) path: Q4D65VKZ3T5NERSB @1589633445440 = 700998', 0, async () => {
      const code = await Otp.generateTOTPCodeString('Q4D65VKZ3T5NERSB', 1589633445440, 6, 30, OtpAlgorithm.sha1, true);
      expect(code).assertEqual('700998');
    });
    it('lowercase base32 secret works', 0, async () => {
      const code = await Otp.generateTOTPCodeString('kzvvz2s2ylhdmxzk', 1679772523111, 6, 30, OtpAlgorithm.sha1, true);
      expect(code).assertEqual('869063');
    });
    it('HOTP isGoogle SHA256 counter 7 = 346239', 0, async () => {
      const code = await Otp.generateHOTPCodeString('JBSWY3DPEHPK3PXP', 7, 6, OtpAlgorithm.sha256, true);
      expect(code).assertEqual('346239');
    });
    it('base32 path RFC4226 GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ counter 0 = 755224', 0, async () => {
      const b32secret = Base32.encode(new TextEncoder().encode('12345678901234567890'));
      expect(b32secret).assertEqual('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
      const code = await Otp.generateHOTPCodeString(b32secret, 0, 6, OtpAlgorithm.sha1, true);
      expect(code).assertEqual('755224');
    });
    it('int2bytes big-endian', 0, () => {
      const b = Otp.int2bytes(0x23523ec);
      expect(hex(b)).assertEqual('00000000023523ec');
    });
  });

  describe('Steam TOTP', () => {
    it('empty secret throws', 0, () => {
      try {
        const s = new SteamTotp('');
        expect(true).assertFalse();
      } catch (e) {
        expect(true).assertTrue();
      }
    });
    it('invalid base32 throws', 0, () => {
      try {
        const s = new SteamTotp('A');
        expect(true).assertFalse();
      } catch (e) {
        expect(true).assertTrue();
      }
    });
    it('negative time throws', 0, async () => {
      try {
        const s = new SteamTotp('AA');
        await s.generate(-1);
        expect(true).assertFalse();
      } catch (e) {
        expect(true).assertTrue();
      }
    });
    it('AA @ 42 = DR2DK (steam_totp 0.0.2 vector)', 0, async () => {
      const s = new SteamTotp('AA');
      const code = await s.generate(42);
      expect(code).assertEqual('DR2DK');
    });
  });

  describe('Code model & otpauth URI parsing', () => {
    it('parses full TOTP uri', 0, () => {
      const code = Code.fromOTPAuthUrl(
        'otpauth://totp/GitHub:octocat@example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&algorithm=SHA1&digits=6&period=30');
      expect(code.issuer).assertEqual('GitHub');
      expect(code.account).assertEqual('octocat@example.com');
      expect(code.secret).assertEqual('JBSWY3DPEHPK3PXP');
      expect(code.digits).assertEqual(6);
      expect(code.period).assertEqual(30);
      expect(code.algorithm).assertEqual(OtpAlgorithm.sha1);
      expect(code.type).assertEqual(OtpType.totp);
      expect(code.counter).assertEqual(0);
      expect(code.issuerAccount).assertEqual('GitHub (octocat@example.com)');
    });
    it('parses HOTP with counter', 0, () => {
      const code = Code.fromOTPAuthUrl(
        'otpauth://hotp/ACME:john@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=ACME&counter=5');
      expect(code.type).assertEqual(OtpType.hotp);
      expect(code.counter).assertEqual(5);
      expect(code.digits).assertEqual(6);
      expect(code.period).assertEqual(30);
    });
    it('steam host → type steam, digits 5', 0, () => {
      const code = Code.fromOTPAuthUrl('otpauth://steam/john:STEAM?secret=JBSWY3DPEHPK3PXP');
      expect(code.type).assertEqual(OtpType.steam);
      expect(code.digits).assertEqual(5);
      expect(code.period).assertEqual(30);
    });
    it('SHA256/SHA512 algorithm detection', 0, () => {
      const c1 = Code.fromOTPAuthUrl('otpauth://totp/x:y?secret=JBSWY3DPEHPK3PXP&algorithm=SHA256');
      const c2 = Code.fromOTPAuthUrl('otpauth://totp/x:y?secret=JBSWY3DPEHPK3PXP&algorithm=sha512');
      const c3 = Code.fromOTPAuthUrl('otpauth://totp/x:y?secret=JBSWY3DPEHPK3PXP&algorithm=algorithm.sha256');
      expect(c1.algorithm).assertEqual(OtpAlgorithm.sha256);
      expect(c2.algorithm).assertEqual(OtpAlgorithm.sha512);
      expect(c3.algorithm).assertEqual(OtpAlgorithm.sha256);
    });
    it('issuer without account', 0, () => {
      const code = Code.fromOTPAuthUrl('otpauth://totp/Issuer?secret=JBSWY3DPEHPK3PXP');
      expect(code.issuer).assertEqual('Issuer');
      expect(code.account).assertEqual('');
    });
    it('issuer param with colon in path', 0, () => {
      const code = Code.fromOTPAuthUrl('otpauth://totp/My%20Company:user?secret=JBSWY3DPEHPK3PXP&issuer=My+Company');
      expect(code.issuer).assertEqual('My Company');
      expect(code.account).assertEqual('user');
    });
    it('missing secret throws', 0, () => {
      try {
        Code.fromOTPAuthUrl('otpauth://totp/x:y?issuer=X');
        expect(true).assertFalse();
      } catch (e) {
        expect(true).assertTrue();
      }
    });
    it('unescaped # in account retried with %23', 0, () => {
      const code = Code.fromOTPAuthUrl('otpauth://totp/Issuer:ab#cd?secret=JBSWY3DPEHPK3PXP');
      expect(code.account).assertEqual('ab#cd');
    });
    it('sanitized secret', 0, () => {
      expect(getSanitizedSecret(' jbsw y3dp ehpk 3pxp ')).assertEqual('JBSWY3DPEHPK3PXP');
    });
    it('codeDisplay embedded JSON roundtrip', 0, () => {
      const code = Code.fromOTPAuthUrl(
        'otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub');
      code.display.note = 'hello';
      code.display.pinned = true;
      const stored = code.toOTPAuthUrlFormat();
      // Stored form is a JSON-encoded string (starts and ends with quotes).
      expect(stored.startsWith('"')).assertTrue();
      expect(stored.endsWith('"')).assertTrue();
      const uriString = JSON.parse(stored) as string;
      expect(uriString.indexOf('codeDisplay=')).assertLarger(-1);
      const reparsed = Code.fromOTPAuthUrl(uriString);
      expect(reparsed.display.note).assertEqual('hello');
      expect(reparsed.display.pinned).assertEqual(true);
      expect(reparsed.secret).assertEqual('JBSWY3DPEHPK3PXP');
      expect(reparsed.rawData.startsWith('otpauth://totp/')).assertTrue();
    });
    it('copyWith rebuilds rawData identically to upstream', 0, () => {
      const code = Code.fromAccountAndSecret(OtpType.totp, 'alice@example.com', 'Ente', 'JBSWY3DPEHPK3PXP', undefined, 6);
      const expected = 'otpauth://totp/Ente:alice@example.com?algorithm=SHA1&digits=6&issuer=Ente&period=30&secret=JBSWY3DPEHPK3PXP';
      expect(code.rawData).assertEqual(expected);
      const updated = code.copyWith(undefined, 'New Issuer & Co.');
      expect(updated.rawData).assertEqual(
        'otpauth://totp/New Issuer & Co.:alice@example.com?algorithm=SHA1&digits=6&issuer=New+Issuer+%26+Co.&period=30&secret=JBSWY3DPEHPK3PXP');
    });
    it('unsupported host throws', 0, () => {
      try {
        Code.fromOTPAuthUrl('otpauth://motp/x:y?secret=JBSWY3DPEHPK3PXP');
        expect(true).assertFalse();
      } catch (e) {
        expect(true).assertTrue();
      }
    });
  });

  describe('UriComponent encoding', () => {
    it('encodeQueryComponent: space -> +, special chars percent-encoded', 0, () => {
      expect(UriComponent.encodeQueryComponent('New Issuer & Co.')).assertEqual('New+Issuer+%26+Co.');
      expect(UriComponent.encodeQueryComponent('a-b.c_d~e')).assertEqual('a-b.c_d~e');
    });
    it('decodeQueryComponent: + -> space', 0, () => {
      expect(UriComponent.decodeQueryComponent('My+Company')).assertEqual('My Company');
    });
    it('decodeComponent: + literal, %XX decoded', 0, () => {
      expect(UriComponent.decodeComponent('My%20Company')).assertEqual('My Company');
      expect(UriComponent.decodeComponent('a+b')).assertEqual('a+b');
    });
    it('strict errors on malformed percent', 0, () => {
      try {
        UriComponent.decodeComponent('ab%');
        expect(true).assertFalse();
      } catch (e) {
        expect(true).assertTrue();
      }
      try {
        UriComponent.decodeComponent('ab%zz');
        expect(true).assertFalse();
      } catch (e) {
        expect(true).assertTrue();
      }
    });
    it('utf8 roundtrip (non-latin)', 0, () => {
      expect(UriComponent.decodeQueryComponent(UriComponent.encodeQueryComponent('日本語テスト'))).assertEqual('日本語テスト');
    });
  });
}