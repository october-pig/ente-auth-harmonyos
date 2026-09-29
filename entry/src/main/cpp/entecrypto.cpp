/*
 * entecrypto — minimal libsodium NAPI bridge for the Ente Auth HarmonyOS port.
 *
 * Exposes ONLY byte-level primitives required for upstream-compatible crypto
 * (ente_crypto_dart @ 981a9e0f4a227023991af3332ef0e6ab6d14a1c2):
 *   - crypto_pwhash (Argon2id v1.3)
 *   - crypto_kdf_derive_from_key (blake2b-based, context "loginctx")
 *   - crypto_secretbox_easy/open_easy (XSalsa20-Poly1305)
 *   - crypto_box_seal / seal_open (X25519 + XSalsa20-Poly1305)
 *   - crypto_secretstream_xchacha20poly1305 (single message)
 *   - randombytes
 *
 * All business logic, state machines and sync live in ArkTS; this module
 * holds no state and never logs secrets.
 *
 * libsodium 1.0.22-RELEASE (ISC license), vendored under third_party/libsodium.
 */
#include "napi/native_api.h"

#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#include <sodium.h>

namespace {

constexpr size_t kKeyBytes = 32;
constexpr size_t kNonceBytes = 24;
constexpr size_t kSaltBytes = 16;
constexpr size_t kStreamHeaderBytes = 24;
constexpr size_t kStreamABytes = 17;
constexpr size_t kBoxPubKeyBytes = 32;
constexpr size_t kBoxSecretKeyBytes = 32;
constexpr size_t kBoxSealBytes = 48;

void throwError(napi_env env, const char* msg) {
  napi_throw_error(env, nullptr, msg);
}

bool getUint8Array(napi_env env, napi_value value, const uint8_t** data, size_t* len,
                   const char* what) {
  napi_typedarray_type type;
  size_t length = 0;
  void* ptr = nullptr;
  napi_value buffer = nullptr;
  size_t offset = 0;
  if (napi_get_typedarray_info(env, value, &type, &length, &ptr, &buffer, &offset) != napi_ok ||
      type != napi_uint8_array) {
    throwError(env, "TypeError: expected Uint8Array");
    return false;
  }
  (void)buffer;
  (void)offset;
  *data = reinterpret_cast<const uint8_t*>(ptr);
  *len = length;
  return true;
}

napi_value makeUint8Array(napi_env env, const void* data, size_t len, bool* ok) {
  void* out = nullptr;
  napi_value buffer = nullptr;
  napi_value arr = nullptr;
  if (napi_create_arraybuffer(env, len, &out, &buffer) != napi_ok) {
    *ok = false;
    return nullptr;
  }
  if (len > 0 && data != nullptr) {
    memcpy(out, data, len);
  }
  if (napi_create_typedarray(env, napi_uint8_array, len, buffer, 0, &arr) != napi_ok) {
    *ok = false;
    return nullptr;
  }
  *ok = true;
  return arr;
}

napi_value makeString(napi_env env, const char* s, bool* ok) {
  napi_value v = nullptr;
  if (napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &v) != napi_ok) {
    *ok = false;
    return nullptr;
  }
  *ok = true;
  return v;
}

bool getUint32(napi_env env, napi_value value, uint32_t* out, const char* what) {
  if (napi_get_value_uint32(env, value, out) != napi_ok) {
    throwError(env, "TypeError: expected unsigned integer");
    return false;
  }
  return true;
}

bool getInt64(napi_env env, napi_value value, int64_t* out, const char* what) {
  if (napi_get_value_int64(env, value, out) != napi_ok) {
    throwError(env, "TypeError: expected integer");
    return false;
  }
  return true;
}

// ---------------- random ----------------

napi_value JsRandomBytes(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  uint32_t len = 0;
  if (argc < 1 || !getUint32(env, argv[0], &len, "len")) {
    return nullptr;
  }
  if (len > 16 * 1024 * 1024) {
    throwError(env, "RangeError: len too large");
    return nullptr;
  }
  bool ok = false;
  napi_value arr = makeUint8Array(env, nullptr, len, &ok);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  uint8_t* data = nullptr;
  size_t length = 0;
  napi_value buffer = nullptr;
  size_t offset = 0;
  napi_get_typedarray_info(env, arr, nullptr, &length, reinterpret_cast<void**>(&data),
                           &buffer, &offset);
  randombytes_buf(data, length);
  return arr;
}

napi_value JsGenerateKey(napi_env env, napi_callback_info info) {
  uint8_t key[kKeyBytes];
  randombytes_buf(key, sizeof key);
  bool ok = false;
  napi_value arr = makeUint8Array(env, key, sizeof key, &ok);
  sodium_memzero(key, sizeof key);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

napi_value JsGetSaltToDeriveKey(napi_env env, napi_callback_info info) {
  uint8_t salt[kSaltBytes];
  randombytes_buf(salt, sizeof salt);
  bool ok = false;
  napi_value arr = makeUint8Array(env, salt, sizeof salt, &ok);
  sodium_memzero(salt, sizeof salt);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

// ---------------- argon2id ----------------

napi_value JsCryptoPwHash(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value argv[4];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 4) {
    throwError(env, "Args: (password: Uint8Array, salt: Uint8Array, opsLimit: u32, memLimit: u32)");
    return nullptr;
  }
  const uint8_t* pw = nullptr;
  size_t pwLen = 0;
  const uint8_t* salt = nullptr;
  size_t saltLen = 0;
  uint32_t opsLimit = 0;
  uint32_t memLimit = 0;
  if (!getUint8Array(env, argv[0], &pw, &pwLen, "password") ||
      !getUint8Array(env, argv[1], &salt, &saltLen, "salt") ||
      !getUint32(env, argv[2], &opsLimit, "opsLimit") ||
      !getUint32(env, argv[3], &memLimit, "memLimit")) {
    return nullptr;
  }
  if (saltLen != kSaltBytes) {
    throwError(env, "Invalid salt length");
    return nullptr;
  }
  // Both limits arrive as uint32_t from the NAPI contract, so the TYPE is the
  // upper bound: a comparison such as `memLimit > 4398046511104ULL` (4 TiB) or
  // `opsLimit > 0xFFFFFFFFULL` can never be true and is dead code (it also drew
  // a compiler warning). The meaningful checks are the lower bounds, which
  // mirror libsodium's own minimums; an over-large memLimit is reported by
  // crypto_pwhash itself, and that failure is surfaced below as
  // "crypto_pwhash failed (out of memory)".
  //
  // Ente's own maximum is PW_MEM_LIMIT_SENSITIVE = 1 GiB (CryptoUtil.ets:26),
  // which fits uint32_t with room to spare.
  if (memLimit < 8192U) {
    throwError(env, "Invalid memLimit");
    return nullptr;
  }
  if (opsLimit < 1U) {
    throwError(env, "Invalid opsLimit");
    return nullptr;
  }
  uint8_t out[kKeyBytes];
  if (crypto_pwhash(out, sizeof out, reinterpret_cast<const char*>(pw), pwLen, salt,
                    opsLimit, memLimit, crypto_pwhash_ALG_ARGON2ID13) != 0) {
    sodium_memzero(out, sizeof out);
    throwError(env, "crypto_pwhash failed (out of memory)");
    return nullptr;
  }
  bool ok = false;
  napi_value arr = makeUint8Array(env, out, sizeof out, &ok);
  sodium_memzero(out, sizeof out);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

// ---------------- kdf ----------------

napi_value JsCryptoKdfDeriveFromKey(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value argv[4];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 4) {
    throwError(env, "Args: (subkeyLen: u32, subkeyId: i64, context: string, key: Uint8Array)");
    return nullptr;
  }
  uint32_t subkeyLen = 0;
  int64_t subkeyId = 0;
  char context[9] = {0};
  size_t contextLen = 0;
  const uint8_t* key = nullptr;
  size_t keyLen = 0;
  if (!getUint32(env, argv[0], &subkeyLen, "subkeyLen") ||
      !getInt64(env, argv[1], &subkeyId, "subkeyId")) {
    return nullptr;
  }
  if (napi_get_value_string_utf8(env, argv[2], context, sizeof context, &contextLen) != napi_ok ||
      contextLen != crypto_kdf_CONTEXTBYTES) {
    throwError(env, "context must be exactly 8 bytes");
    return nullptr;
  }
  if (!getUint8Array(env, argv[3], &key, &keyLen, "key")) {
    return nullptr;
  }
  if (keyLen != crypto_kdf_KEYBYTES) {
    throwError(env, "Invalid key length");
    return nullptr;
  }
  if (subkeyLen < crypto_kdf_BYTES_MIN || subkeyLen > crypto_kdf_BYTES_MAX) {
    throwError(env, "Invalid subkeyLen");
    return nullptr;
  }
  std::vector<uint8_t> out(subkeyLen);
  if (crypto_kdf_derive_from_key(out.data(), subkeyLen, static_cast<uint64_t>(subkeyId),
                                 context, key) != 0) {
    throwError(env, "crypto_kdf_derive_from_key failed");
    return nullptr;
  }
  bool ok = false;
  napi_value arr = makeUint8Array(env, out.data(), subkeyLen, &ok);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

// ---------------- secretbox ----------------

napi_value JsSecretboxEasy(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    throwError(env, "Args: (message: Uint8Array, nonce: Uint8Array, key: Uint8Array)");
    return nullptr;
  }
  const uint8_t* msg = nullptr;
  size_t msgLen = 0;
  const uint8_t* nonce = nullptr;
  size_t nonceLen = 0;
  const uint8_t* key = nullptr;
  size_t keyLen = 0;
  if (!getUint8Array(env, argv[0], &msg, &msgLen, "message") ||
      !getUint8Array(env, argv[1], &nonce, &nonceLen, "nonce") ||
      !getUint8Array(env, argv[2], &key, &keyLen, "key")) {
    return nullptr;
  }
  if (nonceLen != crypto_secretbox_NONCEBYTES || keyLen != crypto_secretbox_KEYBYTES) {
    throwError(env, "Invalid nonce or key length");
    return nullptr;
  }
  std::vector<uint8_t> ct(msgLen + crypto_secretbox_MACBYTES);
  if (crypto_secretbox_easy(ct.data(), msg, msgLen, nonce, key) != 0) {
    throwError(env, "crypto_secretbox_easy failed");
    return nullptr;
  }
  bool ok = false;
  napi_value arr = makeUint8Array(env, ct.data(), ct.size(), &ok);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

napi_value JsSecretboxOpenEasy(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    throwError(env, "Args: (cipher: Uint8Array, nonce: Uint8Array, key: Uint8Array)");
    return nullptr;
  }
  const uint8_t* ct = nullptr;
  size_t ctLen = 0;
  const uint8_t* nonce = nullptr;
  size_t nonceLen = 0;
  const uint8_t* key = nullptr;
  size_t keyLen = 0;
  if (!getUint8Array(env, argv[0], &ct, &ctLen, "cipher") ||
      !getUint8Array(env, argv[1], &nonce, &nonceLen, "nonce") ||
      !getUint8Array(env, argv[2], &key, &keyLen, "key")) {
    return nullptr;
  }
  if (nonceLen != crypto_secretbox_NONCEBYTES || keyLen != crypto_secretbox_KEYBYTES) {
    throwError(env, "Invalid nonce or key length");
    return nullptr;
  }
  if (ctLen < crypto_secretbox_MACBYTES) {
    throwError(env, "Ciphertext too short");
    return nullptr;
  }
  std::vector<uint8_t> out(ctLen - crypto_secretbox_MACBYTES);
  if (crypto_secretbox_open_easy(out.data(), ct, ctLen, nonce, key) != 0) {
    throwError(env, "Decryption failed: ciphertext verification failed");
    return nullptr;
  }
  bool ok = false;
  napi_value arr = makeUint8Array(env, out.data(), out.size(), &ok);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

// ---------------- box seal ----------------

napi_value JsBoxKeyPair(napi_env env, napi_callback_info info) {
  uint8_t pk[crypto_box_PUBLICKEYBYTES];
  uint8_t sk[crypto_box_SECRETKEYBYTES];
  if (crypto_box_keypair(pk, sk) != 0) {
    throwError(env, "crypto_box_keypair failed");
    return nullptr;
  }
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  bool ok = false;
  napi_value pkArr = makeUint8Array(env, pk, sizeof pk, &ok);
  if (!ok) return nullptr;
  napi_value skArr = makeUint8Array(env, sk, sizeof sk, &ok);
  sodium_memzero(sk, sizeof sk);
  if (!ok) return nullptr;
  napi_set_named_property(env, obj, "publicKey", pkArr);
  napi_set_named_property(env, obj, "secretKey", skArr);
  return obj;
}

napi_value JsBoxSeal(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 2) {
    throwError(env, "Args: (message: Uint8Array, publicKey: Uint8Array)");
    return nullptr;
  }
  const uint8_t* msg = nullptr;
  size_t msgLen = 0;
  const uint8_t* pk = nullptr;
  size_t pkLen = 0;
  if (!getUint8Array(env, argv[0], &msg, &msgLen, "message") ||
      !getUint8Array(env, argv[1], &pk, &pkLen, "publicKey")) {
    return nullptr;
  }
  if (pkLen != crypto_box_PUBLICKEYBYTES) {
    throwError(env, "Invalid public key length");
    return nullptr;
  }
  std::vector<uint8_t> ct(msgLen + crypto_box_SEALBYTES);
  if (crypto_box_seal(ct.data(), msg, msgLen, pk) != 0) {
    throwError(env, "crypto_box_seal failed");
    return nullptr;
  }
  bool ok = false;
  napi_value arr = makeUint8Array(env, ct.data(), ct.size(), &ok);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

napi_value JsBoxSealOpen(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    throwError(env, "Args: (cipher: Uint8Array, publicKey: Uint8Array, secretKey: Uint8Array)");
    return nullptr;
  }
  const uint8_t* ct = nullptr;
  size_t ctLen = 0;
  const uint8_t* pk = nullptr;
  size_t pkLen = 0;
  const uint8_t* sk = nullptr;
  size_t skLen = 0;
  if (!getUint8Array(env, argv[0], &ct, &ctLen, "cipher") ||
      !getUint8Array(env, argv[1], &pk, &pkLen, "publicKey") ||
      !getUint8Array(env, argv[2], &sk, &skLen, "secretKey")) {
    return nullptr;
  }
  if (pkLen != crypto_box_PUBLICKEYBYTES || skLen != crypto_box_SECRETKEYBYTES) {
    throwError(env, "Invalid key length");
    return nullptr;
  }
  if (ctLen < crypto_box_SEALBYTES) {
    throwError(env, "Ciphertext too short");
    return nullptr;
  }
  std::vector<uint8_t> out(ctLen - crypto_box_SEALBYTES);
  if (crypto_box_seal_open(out.data(), ct, ctLen, pk, sk) != 0) {
    throwError(env, "Decryption failed: ciphertext verification failed");
    return nullptr;
  }
  bool ok = false;
  napi_value arr = makeUint8Array(env, out.data(), out.size(), &ok);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

// ---------------- secretstream (single message) ----------------

napi_value JsSecretstreamEncrypt(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 2) {
    throwError(env, "Args: (key: Uint8Array, message: Uint8Array)");
    return nullptr;
  }
  const uint8_t* key = nullptr;
  size_t keyLen = 0;
  const uint8_t* msg = nullptr;
  size_t msgLen = 0;
  if (!getUint8Array(env, argv[0], &key, &keyLen, "key") ||
      !getUint8Array(env, argv[1], &msg, &msgLen, "message")) {
    return nullptr;
  }
  if (keyLen != crypto_secretstream_xchacha20poly1305_KEYBYTES) {
    throwError(env, "Invalid key length");
    return nullptr;
  }
  if (msgLen > (1u << 31)) {
    throwError(env, "Message too large");
    return nullptr;
  }
  crypto_secretstream_xchacha20poly1305_state st;
  unsigned char header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
  std::vector<uint8_t> ct(msgLen + crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long ctLen = 0;
  if (crypto_secretstream_xchacha20poly1305_init_push(&st, header, key) != 0) {
    throwError(env, "secretstream init_push failed");
    return nullptr;
  }
  if (crypto_secretstream_xchacha20poly1305_push(&st, ct.data(), &ctLen, msg, msgLen,
                                                 nullptr, 0,
                                                 crypto_secretstream_xchacha20poly1305_TAG_FINAL) != 0) {
    throwError(env, "secretstream push failed");
    return nullptr;
  }
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  bool ok = false;
  napi_value hArr = makeUint8Array(env, header, sizeof header, &ok);
  if (!ok) return nullptr;
  napi_value ctArr = makeUint8Array(env, ct.data(), ctLen, &ok);
  if (!ok) return nullptr;
  napi_set_named_property(env, obj, "header", hArr);
  napi_set_named_property(env, obj, "ciphertext", ctArr);
  sodium_memzero(&st, sizeof st);
  return obj;
}

napi_value JsSecretstreamDecrypt(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3) {
    throwError(env, "Args: (key: Uint8Array, header: Uint8Array, ciphertext: Uint8Array)");
    return nullptr;
  }
  const uint8_t* key = nullptr;
  size_t keyLen = 0;
  const uint8_t* header = nullptr;
  size_t headerLen = 0;
  const uint8_t* ct = nullptr;
  size_t ctLen = 0;
  if (!getUint8Array(env, argv[0], &key, &keyLen, "key") ||
      !getUint8Array(env, argv[1], &header, &headerLen, "header") ||
      !getUint8Array(env, argv[2], &ct, &ctLen, "ciphertext")) {
    return nullptr;
  }
  if (keyLen != crypto_secretstream_xchacha20poly1305_KEYBYTES) {
    throwError(env, "Invalid key length");
    return nullptr;
  }
  if (headerLen != crypto_secretstream_xchacha20poly1305_HEADERBYTES) {
    throwError(env, "Invalid header length");
    return nullptr;
  }
  if (ctLen < crypto_secretstream_xchacha20poly1305_ABYTES) {
    throwError(env, "Ciphertext too short");
    return nullptr;
  }
  crypto_secretstream_xchacha20poly1305_state st;
  if (crypto_secretstream_xchacha20poly1305_init_pull(&st, header, key) != 0) {
    throwError(env, "secretstream init_pull failed");
    return nullptr;
  }
  std::vector<uint8_t> out(ctLen - crypto_secretstream_xchacha20poly1305_ABYTES);
  unsigned long long outLen = 0;
  unsigned char tag = 0;
  if (crypto_secretstream_xchacha20poly1305_pull(&st, out.data(), &outLen, &tag, ct, ctLen,
                                                 nullptr, 0) != 0) {
    sodium_memzero(&st, sizeof st);
    throwError(env, "Decryption failed: ciphertext verification failed");
    return nullptr;
  }
  sodium_memzero(&st, sizeof st);
  bool ok = false;
  napi_value arr = makeUint8Array(env, out.data(), outLen, &ok);
  if (!ok) {
    throwError(env, "Failed to allocate output");
    return nullptr;
  }
  return arr;
}

// ---------------- module registration ----------------

napi_value Init(napi_env env, napi_value exports) {
  if (sodium_init() < 0) {
    throwError(env, "sodium_init failed");
    return nullptr;
  }
  const struct {
    const char* name;
    napi_callback fn;
  } kFns[] = {
      {"randomBytes", JsRandomBytes},
      {"generateKey", JsGenerateKey},
      {"getSaltToDeriveKey", JsGetSaltToDeriveKey},
      {"cryptoPwHash", JsCryptoPwHash},
      {"cryptoKdfDeriveFromKey", JsCryptoKdfDeriveFromKey},
      {"secretboxEasy", JsSecretboxEasy},
      {"secretboxOpenEasy", JsSecretboxOpenEasy},
      {"boxKeyPair", JsBoxKeyPair},
      {"boxSeal", JsBoxSeal},
      {"boxSealOpen", JsBoxSealOpen},
      {"secretstreamEncrypt", JsSecretstreamEncrypt},
      {"secretstreamDecrypt", JsSecretstreamDecrypt},
  };
  for (const auto& f : kFns) {
    napi_value fn = nullptr;
    if (napi_create_function(env, f.name, NAPI_AUTO_LENGTH, f.fn, nullptr, &fn) != napi_ok ||
        napi_set_named_property(env, exports, f.name, fn) != napi_ok) {
      throwError(env, "Failed to export function");
      return nullptr;
    }
  }
  return exports;
}

}  // namespace

#ifdef __cplusplus
extern "C" {
#endif
static napi_value InitWrapper(napi_env env, napi_value exports) { return Init(env, exports); }
#ifdef __cplusplus
}
#endif

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = InitWrapper,
    .nm_modname = "entecrypto",
    .nm_priv = ((void*)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntecryptoModule(void) {
  napi_module_register(&g_module);
}