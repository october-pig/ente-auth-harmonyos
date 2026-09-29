/**
 * SecureStore — encrypted key-value storage backed by HUKS (Universal
 * Keystore Kit) + Preferences for ciphertext, replacing the role of
 * flutter_secure_storage in upstream Ente Auth.
 *
 * Each logical key maps to a HUKS AES-256-GCM key alias; values are encrypted
 * with a fresh 12-byte nonce and stored as base64(nonce || tag || ciphertext)
 * in the app preferences. Keys never leave HUKS.
 *
 * Used for: "key" (master key), "secret_key", "auth_secret_key",
 * "offline_auth_secret_key", "autoBackupPassword".
 */
import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Preferences } from './Preferences';
import { CryptoUtil } from '../crypto/CryptoUtil';
import { toError } from '../utils/Errors';

const ALIAS_PREFIX: string = 'ente_ss_';
const TAG_BYTES: number = 16;
const NONCE_BYTES: number = 12;

function concat(parts: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (let i = 0; i < parts.length; i++) {
    total += parts[i].length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (let i = 0; i < parts.length; i++) {
    out.set(parts[i], offset);
    offset += parts[i].length;
  }
  return out;
}

function endsWith(haystack: Uint8Array, needle: Uint8Array): boolean {
  if (needle.length === 0 || haystack.length < needle.length) {
    return false;
  }
  const start: number = haystack.length - needle.length;
  for (let i = 0; i < needle.length; i++) {
    if (haystack[start + i] !== needle[i]) {
      return false;
    }
  }
  return true;
}

function genProps(purpose: number, nonce: Uint8Array | undefined,
  tag: Uint8Array | undefined): huks.HuksParam[] {
  const props: huks.HuksParam[] = [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
  ];
  if (nonce !== undefined) {
    props.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
  }
  if (tag !== undefined) {
    props.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
  }
  return props;
}

/** Empty property set, as the SDK examples use for existence checks. */
function emptyOptions(): huks.HuksOptions {
  return { properties: [] };
}

/**
 * Ensure the HUKS key for `alias` exists, creating it ONLY when it does not.
 *
 *   hasKeyItem(alias) ──true──►  reuse the existing key (no generation at all)
 *           │
 *           └──false──►  generateKeyItem(alias)
 *
 * This is deliberately NOT implemented as "call generateKeyItem and treat a
 * duplicate-alias failure as success". Two platform facts make that unsound
 * (verified against the installed SDK 26.0.0.105 declarations AND the HarmonyOS
 * Developer Knowledge MCP; see docs/TESTING.md finding A):
 *
 *  1. `generateKeyItem` documents exactly ONE outcome for a pre-existing alias:
 *       @throws { BusinessError } 12000017 - The key with the same alias already exists
 *     (@ohos.security.huks.d.ts:97 and :148; HUKS_ERR_CODE_KEY_ALREADY_EXIST,
 *     HuksExceptionErrCode, @since 20). There is no documented idempotent
 *     success path and no documented overwrite.
 *  2. Whether a same-named key is overwritten at all is governed by
 *     HUKS_TAG_KEY_OVERRIDE (tag 520, @since 20), which this code does not set.
 *
 * So "duplicate generate" is not a contract: it is an undocumented,
 * API-level-dependent error path. Keying the lifetime of every stored secret off
 * it would be exactly the kind of magic-code coupling this port must not have.
 * (The previous implementation compared against error code 629, which does not
 * exist anywhere in the SDK or in the HUKS error-code reference — so the guard
 * was in fact ALWAYS true and rethrew, meaning a second write to the same
 * logical key failed outright on device.)
 *
 * `hasKeyItem` is the API Huawei recommends for this check (FAQ
 * faqs-universal-keystore-12). Unlike `isKeyItemExist`, it reports absence as
 * `false` instead of through its error channel.
 */
async function ensureKey(alias: string): Promise<void> {
  if (await huks.hasKeyItem(alias, emptyOptions())) {
    return;
  }
  const options: huks.HuksOptions = {
    properties: [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      {
        tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT,
      },
    ],
  };
  try {
    await huks.generateKeyItem(alias, options);
  } catch (e) {
    // CHECK-THEN-CREATE RACE (finding Q). Two concurrent writers for the same
    // alias can both observe "absent", and the loser's generate then fails.
    //
    // The failure is resolved by ASKING THE KEYSTORE AGAIN, never by
    // interpreting the error code — that would reintroduce exactly the
    // magic-code coupling this function was rewritten to remove:
    //
    //   alias now exists -> another caller won the race; reuse its key
    //   alias still absent -> the failure is real; propagate it unchanged
    //
    // The second branch is what keeps this safe: it can never manufacture a key
    // or mask a genuine generation failure.
    if (await huks.hasKeyItem(alias, emptyOptions())) {
      return;
    }
    // ArkTS restricts `throw` to Error values (`arkts-limited-throw`), so the
    // caught value is normalised rather than rethrown raw.
    throw toError(e);
  }
}

export class SecureStore {
  private constructor() {
  }

  static async set(key: string, value: string): Promise<void> {
    const alias: string = ALIAS_PREFIX + key;
    await ensureKey(alias);
    const nonce: Uint8Array = cryptoFramework.createRandom().generateRandomSync(NONCE_BYTES).data;
    const props: huks.HuksParam[] = genProps(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce, undefined);
    const plain: Uint8Array = CryptoUtil.strToBin(value);
    const session = await huks.initSession(alias, { properties: props });
    const finish = await huks.finishSession(session.handle, { inData: plain, properties: props });
    let ct: Uint8Array = finish.outData as Uint8Array;
    let tag: Uint8Array = new Uint8Array(0);
    // GCM: HUKS implementations differ — the AEAD tag is returned through the
    // result properties, appended to outData, or BOTH. Normalise so exactly one
    // copy of the tag is stored, otherwise set() and get() disagree and every
    // value becomes undecryptable.
    const retProps: huks.HuksParam[] = finish.properties === undefined ? [] : finish.properties;
    for (let i = 0; i < retProps.length; i++) {
      if (retProps[i].tag === huks.HuksTag.HUKS_TAG_AE_TAG) {
        tag = retProps[i].value as Uint8Array;
        break;
      }
    }
    if (tag.length === TAG_BYTES) {
      // Tag came back explicitly; drop it from outData if it was appended too.
      if (endsWith(ct, tag)) {
        ct = ct.subarray(0, ct.length - TAG_BYTES);
      }
    } else if (ct.length >= TAG_BYTES) {
      // Tag was appended to the ciphertext only.
      tag = ct.subarray(ct.length - TAG_BYTES);
      ct = ct.subarray(0, ct.length - TAG_BYTES);
    } else {
      throw new Error('HUKS returned no AE tag for GCM encryption');
    }
    const blob: Uint8Array = concat([nonce, tag, ct]);
    await Preferences.setString('secstore:' + key, CryptoUtil.bin2base64(blob));
  }

  static async get(key: string): Promise<string | undefined> {
    const alias: string = ALIAS_PREFIX + key;
    const stored: string | undefined = await Preferences.getString('secstore:' + key);
    if (stored === undefined || stored === '') {
      return undefined;
    }
    const blob: Uint8Array = CryptoUtil.base642bin(stored);
    if (blob.length < NONCE_BYTES + TAG_BYTES) {
      return undefined;
    }
    const nonce: Uint8Array = blob.subarray(0, NONCE_BYTES);
    const tag: Uint8Array = blob.subarray(NONCE_BYTES, NONCE_BYTES + TAG_BYTES);
    const ct: Uint8Array = blob.subarray(NONCE_BYTES + TAG_BYTES);
    const props: huks.HuksParam[] = genProps(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, nonce, tag);
    const session = await huks.initSession(alias, { properties: props });
    const finish = await huks.finishSession(session.handle, { inData: ct, properties: props });
    const plain: Uint8Array = finish.outData as Uint8Array;
    return StrictUtf8.decode(plain);
  }

  static async contains(key: string): Promise<boolean> {
    const stored: string | undefined = await Preferences.getString('secstore:' + key);
    return stored !== undefined && stored !== '';
  }

  static async delete(key: string): Promise<void> {
    await Preferences.remove('secstore:' + key);
    const alias: string = ALIAS_PREFIX + key;
    // `deleteKeyItem` reports a missing alias as an error (12000011,
    // HUKS_ERR_CODE_ITEM_NOT_EXIST — @ohos.security.huks.d.ts:213,:247), not as a
    // no-op. Existence is therefore checked explicitly: deletion stays
    // idempotent without a catch-all that would also hide a real deletion
    // failure (e.g. the key being in use, or a keystore fault).
    if (await huks.hasKeyItem(alias, emptyOptions())) {
      await huks.deleteKeyItem(alias, emptyOptions());
    }
  }
}

/** Strict UTF-8 decoder (deterministic; no API dependency). */
class StrictUtf8 {
  static decode(bytes: Uint8Array): string {
    let out: string = '';
    let i: number = 0;
    while (i < bytes.length) {
      const b0: number = bytes[i];
      if (b0 < 0x80) {
        out += String.fromCharCode(b0);
        i++;
      } else if ((b0 & 0xE0) === 0xC0) {
        const cp: number = ((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F);
        out += String.fromCharCode(cp);
        i += 2;
      } else if ((b0 & 0xF0) === 0xE0) {
        const cp: number = ((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F);
        out += String.fromCharCode(cp);
        i += 3;
      } else {
        const cp: number = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) |
          ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
        const adjusted: number = cp - 0x10000;
        out += String.fromCharCode(0xD800 + (adjusted >> 10), 0xDC00 + (adjusted & 0x3FF));
        i += 4;
      }
    }
    return out;
  }
}