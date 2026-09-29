cmake_minimum_required(VERSION 3.5.0)
project(entecrypto)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(LIBSODIUM ${NATIVERENDER_ROOT_PATH}/third_party/libsodium)

# --- generate sodium/version.h from version.h.in using 1.0.22 constants ---
set(VERSION "1.0.22")
set(SODIUM_LIBRARY_VERSION_MAJOR "26")
set(SODIUM_LIBRARY_VERSION_MINOR "4")
set(SODIUM_LIBRARY_MINIMAL_DEF "")
configure_file(
  ${LIBSODIUM}/src/libsodium/include/sodium/version.h.in
  ${CMAKE_BINARY_DIR}/generated/include/version.h
  @ONLY
)
configure_file(
  ${LIBSODIUM}/src/libsodium/include/sodium/version.h.in
  ${CMAKE_BINARY_DIR}/generated/include/sodium/version.h
  @ONLY
)

# --- libsodium sources (portable subset; no SIMD/intrinsics variants) ---
file(GLOB_RECURSE SODIUM_SOURCES CONFIGURE_DEPENDS
  ${LIBSODIUM}/src/libsodium/sodium/*.c
  ${LIBSODIUM}/src/libsodium/randombytes/*.c
  ${LIBSODIUM}/src/libsodium/randombytes/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_aead/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_aead/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_auth/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_box/*.c
  ${LIBSODIUM}/src/libsodium/crypto_box/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_box/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_core/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_core/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_generichash/*.c
  ${LIBSODIUM}/src/libsodium/crypto_generichash/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_generichash/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_hash/*.c
  ${LIBSODIUM}/src/libsodium/crypto_hash/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_kdf/*.c
  ${LIBSODIUM}/src/libsodium/crypto_kdf/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_onetimeauth/*.c
  ${LIBSODIUM}/src/libsodium/crypto_onetimeauth/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_onetimeauth/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_pwhash/*.c
  ${LIBSODIUM}/src/libsodium/crypto_pwhash/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_pwhash/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_scalarmult/*.c
  ${LIBSODIUM}/src/libsodium/crypto_scalarmult/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_secretbox/*.c
  ${LIBSODIUM}/src/libsodium/crypto_secretbox/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_secretstream/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_stream/*.c
  ${LIBSODIUM}/src/libsodium/crypto_stream/*/*/*.c
  ${LIBSODIUM}/src/libsodium/crypto_verify/*.c
  ${LIBSODIUM}/src/libsodium/crypto_verify/*/*/*.c
)

# SIMD/intrinsics or unwanted implementation variants
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "aes256gcm")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "sandy2x")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "dolbeau")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "crypto_sign")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "scalarmult/ed25519")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "ristretto")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "crypto_kx")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "crypto_shorthash")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "crypto_kem")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "crypto_xof")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "crypto_ipcrypt")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "crypto_hash/sha3")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "hmacsha1")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "aesni|armcrypto")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "argon2-fill-block-(avx2|avx512f|ssse3|wasm32)")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "blake2b-compress-(avx2|sse41|ssse3)")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "poly1305_(donna32|sse2)")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "chacha20-(avx2|ssse3)")
list(FILTER SODIUM_SOURCES EXCLUDE REGEX "\\.(S|s)$")

# Argon2's NEON fill-block implementation is required on arm64 (referenced
# unconditionally by argon2-core.c there); the reference implementation is
# used everywhere else.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm")
  list(APPEND SODIUM_SOURCES ${LIBSODIUM}/src/libsodium/crypto_pwhash/argon2/argon2-fill-block-neon.c)
endif()

add_library(sodium_static STATIC ${SODIUM_SOURCES})
target_include_directories(sodium_static PUBLIC
  ${LIBSODIUM}/src/libsodium/include
  ${LIBSODIUM}/src/libsodium/include/sodium
  ${CMAKE_BINARY_DIR}/generated/include
)
target_compile_definitions(sodium_static PUBLIC SODIUM_STATIC NATIVE_LIBSODIUM)
target_compile_options(sodium_static PRIVATE -O2 -fvisibility=hidden -w)

# --- NAPI bridge ---
add_library(entecrypto SHARED entecrypto.cpp)
target_include_directories(entecrypto PRIVATE
  ${NATIVERENDER_ROOT_PATH}
  ${LIBSODIUM}/src/libsodium/include
  ${CMAKE_BINARY_DIR}/generated/include
)
target_link_libraries(entecrypto PUBLIC libace_napi.z.so sodium_static)
target_compile_definitions(entecrypto PRIVATE SODIUM_STATIC)
set_target_properties(entecrypto PROPERTIES CXX_STANDARD 17)

# OHOS toolchain flags
if (${OHOS_ARCH} STREQUAL "arm64-v8a" OR ${OHOS_ARCH} STREQUAL "x86_64")
  target_compile_options(entecrypto PRIVATE -O2 -fvisibility=hidden)
endif()