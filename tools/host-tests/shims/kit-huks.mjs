/**
 * kit-huks.mjs — host model of `@kit.UniversalKeystoreKit` (HUKS).
 *
 * IMPORTANT SCOPE NOTE
 * --------------------
 * HUKS is a hardware-backed keystore. This shim is a *software model* built on
 * node:crypto AES-256-GCM. It exists so that the ArkTS storage/sync logic that
 * sits ON TOP of HUKS (SecureStore, Configuration, AuthenticatorService) can be
 * executed and tested on the host.
 *
 * MOCK FIDELITY RULE
 * ------------------
 * Every platform behaviour modelled here is either (A) a documented/SDK-verified
 * contract, or (B) explicitly marked `TEST MODEL ASSUMPTION`. Production code and
 * this shim must never share an *unverified* belief, because a test that encodes
 * the same wrong assumption as production proves nothing.
 *
 * (A) Documented / SDK-verified in this revision
 *     Source: `@ohos.security.huks.d.ts` in DevEco SDK 26.0.0.105
 *     (`sdk/default/openharmony/ets/api/`), cross-checked against the HarmonyOS
 *     Developer Knowledge MCP (`js-apis-huks`, `errorcode-huks`,
 *     `faqs-universal-keystore-12`).
 *
 *   - `generateKeyItem` on an existing alias throws **12000017**
 *     (`HUKS_ERR_CODE_KEY_ALREADY_EXIST`, `HuksExceptionErrCode`, @since 20):
 *     `@throws { BusinessError } 12000017 - The key with the same alias already exists`
 *     (d.ts:97, :148). There is NO documented overwrite and NO documented
 *     idempotent success path.
 *   - Error code **629 does not exist** anywhere in the SDK or the HUKS
 *     error-code reference. The previous revision of this shim invented it, and
 *     production relied on it — which is precisely how an unverified belief
 *     became "verified" by its own mock. It has been removed.
 *   - `hasKeyItem(alias, options): Promise<boolean>` (@since 11) resolves
 *     **false** when the alias is absent (d.ts:730-732, :768-769).
 *   - `deleteKeyItem` on a missing alias throws **12000011**
 *     (`HUKS_ERR_CODE_ITEM_NOT_EXIST`, d.ts:213, :247) — not a no-op.
 *   - AES-256-GCM, 12-byte nonce, 16-byte AE tag.
 *
 * (B) TEST MODEL ASSUMPTION
 *   - `isKeyItemExist` reports absence through its error channel: the FAQ
 *     (`faqs-universal-keystore-12`) says the caller must read the error code,
 *     while the d.ts declares a plain `Promise<boolean>`. The two sources
 *     disagree, so this is modelled per the FAQ and marked as an assumption.
 *     Production does not call it.
 *   - The AE tag is appended to `outData` *and* returned in `properties`. The
 *     real layouts vary by implementation; `SecureStore` normalises both.
 *
 * It does NOT prove anything about real HUKS behaviour on a device: hardware key
 * isolation, key attestation, cross-process persistence and device-specific
 * error codes remain DEVICE_REQUIRED. See docs/TESTING.md.
 */
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';


export const HuksKeyPurpose = Object.freeze({
  HUKS_KEY_PURPOSE_ENCRYPT: 1,
  HUKS_KEY_PURPOSE_DECRYPT: 2,
  HUKS_KEY_PURPOSE_SIGN: 4,
  HUKS_KEY_PURPOSE_VERIFY: 8,
});

export const HuksKeyPadding = Object.freeze({
  HUKS_PADDING_NONE: 0,
  HUKS_PADDING_OAEP: 1,
  HUKS_PADDING_PSS: 2,
  HUKS_PADDING_PKCS1_V1_5: 3,
  HUKS_PADDING_PKCS5: 4,
  HUKS_PADDING_PKCS7: 5,
});

export const HuksCipherMode = Object.freeze({
  HUKS_MODE_ECB: 1,
  HUKS_MODE_CBC: 2,
  HUKS_MODE_CTR: 3,
  HUKS_MODE_OFB: 4,
  HUKS_MODE_CFB: 5,
  HUKS_MODE_CCM: 31,
  HUKS_MODE_GCM: 32,
});

export const HuksKeyAlg = Object.freeze({
  HUKS_ALG_RSA: 1,
  HUKS_ALG_ECC: 2,
  HUKS_ALG_DSA: 3,
  HUKS_ALG_AES: 20,
  HUKS_ALG_HMAC: 50,
});

export const HuksKeySize = Object.freeze({
  HUKS_RSA_KEY_SIZE_2048: 2048,
  HUKS_AES_KEY_SIZE_128: 128,
  HUKS_AES_KEY_SIZE_192: 192,
  HUKS_AES_KEY_SIZE_256: 256,
});

export const HuksKeyDigest = Object.freeze({ HUKS_DIGEST_NONE: 0, HUKS_DIGEST_SHA256: 1000 });

export const HuksTag = Object.freeze({
  HUKS_TAG_ALGORITHM: 1,
  HUKS_TAG_PURPOSE: 2,
  HUKS_TAG_KEY_SIZE: 3,
  HUKS_TAG_DIGEST: 4,
  HUKS_TAG_PADDING: 5,
  HUKS_TAG_BLOCK_MODE: 6,
  HUKS_TAG_NONCE: 1003,
  HUKS_TAG_ASSOCIATED_DATA: 1004,
  HUKS_TAG_AE_TAG: 1005,
  HUKS_TAG_IV: 1006,
});

export const HuksExceptionErrCode = Object.freeze({
  HUKS_ERR_CODE_ITEM_NOT_EXIST: 12000011,
  HUKS_ERR_CODE_ILLEGAL_ARGUMENT: 12000003,
  HUKS_ERR_CODE_INVALID_CRYPTO_OP: 12000012,
  /** @ohos.security.huks.d.ts:2774 — "A key with the same name already exists." @since 20 */
  HUKS_ERR_CODE_KEY_ALREADY_EXIST: 12000017,
  /** @ohos.security.huks.d.ts:2792 — "A provider with the same name has been registered." @since 22 */
  HUKS_ERR_CODE_ITEM_EXISTS: 12000019,
});

/** alias -> 32-byte key. */
const keyStore = new Map();
/**
 * alias -> how many times `generateKeyItem` ACTUALLY created that alias.
 * Test instrument only. It exposes no key material, only a count, which is what
 * "the key was not rotated" has to be asserted against.
 */
const generationCounts = new Map();
/** handle -> { alias, mode, iv, tag, aad } */
const sessions = new Map();
let nextHandle = 1;

function propValue(properties, tag) {
  if (!Array.isArray(properties)) return undefined;
  for (const p of properties) {
    if (p && p.tag === tag) return p.value;
  }
  return undefined;
}

function err(code, message) {
  const e = new Error(message);
  e.code = code;
  return e;
}

export const huks = {
  HuksKeyPurpose,
  HuksKeyPadding,
  HuksCipherMode,
  HuksKeyAlg,
  HuksKeySize,
  HuksKeyDigest,
  HuksTag,
  HuksExceptionErrCode,

  async generateKeyItem(alias, options = {}) {
    if (keyStore.has(alias)) {
      // Documented contract (d.ts:97,:148): a pre-existing alias is an ERROR.
      throw err(HuksExceptionErrCode.HUKS_ERR_CODE_KEY_ALREADY_EXIST,
        `The key with the same alias already exists: ${alias}`);
    }
    const size = propValue(options.properties, HuksTag.HUKS_TAG_KEY_SIZE) ?? 256;
    const bytes = size / 8;
    keyStore.set(alias, randomBytes(bytes));
    generationCounts.set(alias, (generationCounts.get(alias) ?? 0) + 1);
  },

  async initSession(alias, options = {}) {
    if (!keyStore.has(alias)) {
      throw err(HuksExceptionErrCode.HUKS_ERR_CODE_ITEM_NOT_EXIST, `key alias ${alias} not found`);
    }
    const props = options.properties ?? [];
    const purpose = propValue(props, HuksTag.HUKS_TAG_PURPOSE);
    const mode = propValue(props, HuksTag.HUKS_TAG_BLOCK_MODE);
    if (mode !== HuksCipherMode.HUKS_MODE_GCM) {
      throw err(HuksExceptionErrCode.HUKS_ERR_CODE_ILLEGAL_ARGUMENT, 'host model supports GCM only');
    }
    const nonce = propValue(props, HuksTag.HUKS_TAG_NONCE);
    const tag = propValue(props, HuksTag.HUKS_TAG_AE_TAG);
    const aad = propValue(props, HuksTag.HUKS_TAG_ASSOCIATED_DATA);
    const handle = nextHandle++;
    sessions.set(handle, {
      alias,
      purpose,
      mode,
      nonce: nonce ? Uint8Array.from(nonce) : undefined,
      tag: tag ? Uint8Array.from(tag) : undefined,
      aad: aad ? Uint8Array.from(aad) : undefined,
    });
    return { handle };
  },

  async updateSession(handle, options = {}) {
    const s = sessions.get(handle);
    if (!s) throw err(HuksExceptionErrCode.HUKS_ERR_CODE_INVALID_CRYPTO_OP, 'unknown session handle');
    // GCM is single-shot in this model: buffer and let finishSession do the work.
    s.buffered = options.inData ? Uint8Array.from(options.inData) : new Uint8Array(0);
    return { outData: new Uint8Array(0) };
  },

  async finishSession(handle, options = {}) {
    const s = sessions.get(handle);
    if (!s) throw err(HuksExceptionErrCode.HUKS_ERR_CODE_INVALID_CRYPTO_OP, 'unknown session handle');
    const key = keyStore.get(s.alias);
    const inData = Uint8Array.from(
      options.inData ?? s.buffered ?? new Uint8Array(0));
    sessions.delete(handle);
    try {
      if (s.purpose === HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT) {
        const iv = s.nonce ?? randomBytes(12);
        const cipher = createCipheriv('aes-256-gcm', Buffer.from(key), Buffer.from(iv));
        if (s.aad) cipher.setAAD(Buffer.from(s.aad));
        const ct = Buffer.concat([cipher.update(Buffer.from(inData)), cipher.final()]);
        const tag = cipher.getAuthTag();
        // HUKS appends the AE tag to outData on most implementations.
        return {
          outData: new Uint8Array(Buffer.concat([ct, tag])),
          properties: [{ tag: HuksTag.HUKS_TAG_AE_TAG, value: new Uint8Array(tag) }],
        };
      }
      if (s.purpose === HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT) {
        if (!s.nonce) throw err(HuksExceptionErrCode.HUKS_ERR_CODE_ILLEGAL_ARGUMENT, 'GCM needs a nonce');
        if (!s.tag || s.tag.length !== 16) {
          throw err(HuksExceptionErrCode.HUKS_ERR_CODE_ILLEGAL_ARGUMENT, 'GCM needs a 16-byte AE tag');
        }
        const decipher = createDecipheriv(
          'aes-256-gcm', Buffer.from(key), Buffer.from(s.nonce));
        if (s.aad) decipher.setAAD(Buffer.from(s.aad));
        decipher.setAuthTag(Buffer.from(s.tag));
        const pt = Buffer.concat([decipher.update(Buffer.from(inData)), decipher.final()]);
        return { outData: new Uint8Array(pt), properties: [] };
      }
      throw err(HuksExceptionErrCode.HUKS_ERR_CODE_ILLEGAL_ARGUMENT, 'unsupported purpose');
    } catch (e) {
      if (e.code) throw e;
      throw err(HuksExceptionErrCode.HUKS_ERR_CODE_INVALID_CRYPTO_OP,
        `crypto operation failed: ${e.message}`);
    }
  },

  async deleteKeyItem(alias) {
    if (!keyStore.has(alias)) {
      // Documented (d.ts:213,:247): deleting a missing alias is an ERROR, not a
      // no-op. Production checks hasKeyItem first.
      throw err(HuksExceptionErrCode.HUKS_ERR_CODE_ITEM_NOT_EXIST,
        `queried entity does not exist: ${alias}`);
    }
    keyStore.delete(alias);
    generationCounts.delete(alias);
  },

  /**
   * Recommended existence check (d.ts:785). Resolves `false` when absent.
   * This is the only existence API production uses.
   */
  async hasKeyItem(alias) {
    return keyStore.has(alias);
  },

  /**
   * TEST MODEL ASSUMPTION. The FAQ says absence is reported through the error
   * channel (12000011); the d.ts declares a plain `Promise<boolean>`. Modelled
   * per the FAQ. Production does not call this — `hasKeyItem` is used instead.
   */
  async isKeyItemExist(alias) {
    if (!keyStore.has(alias)) {
      throw err(HuksExceptionErrCode.HUKS_ERR_CODE_ITEM_NOT_EXIST,
        `key alias ${alias} not found`);
    }
    return true;
  },
};

/** Test helpers. No key material is ever exposed — only counters and alias names. */
export function __resetHuks() {
  keyStore.clear();
  generationCounts.clear();
  sessions.clear();
  nextHandle = 1;
}
export function __huksAliases() {
  return [...keyStore.keys()].sort();
}
/** How many times the key for `alias` was actually generated. 0 if never. */
export function __huksGenerationCount(alias) {
  return generationCounts.get(alias) ?? 0;
}
/** Total key generations across all aliases. */
export function __huksTotalGenerations() {
  let total = 0;
  for (const n of generationCounts.values()) total += n;
  return total;
}

export default { huks };
