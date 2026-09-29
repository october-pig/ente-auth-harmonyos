# Upstream and third-party notices

This is a derivative, unofficial HarmonyOS port, distributed under AGPL-3.0.
Copyright in upstream Ente code and assets remains with Ente and its contributors;
HarmonyOS adaptation copyright remains with its contributors. It is not an
official Ente release and has no Ente endorsement. See the full [LICENSE](LICENSE).

| Component | Origin / version | License / notice |
| --- | --- | --- |
| Ente Auth behavior, translated code and icon | [Ente](https://github.com/ente-io/ente/tree/3cc9103a3126de07f79a4465cf0b9922903de54b), pinned `3cc9103a3126de07f79a4465cf0b9922903de54b` | AGPL-3.0; retain upstream copyright notices |
| Native libsodium source | Vendored libsodium 1.0.22, [upstream](https://github.com/jedisct1/libsodium) | [ISC license](entry/src/main/cpp/third_party/libsodium/LICENSE), [authors](entry/src/main/cpp/third_party/libsodium/AUTHORS) and per-file notices retained |
| SRP group reference (tests only) | [pointycastle 3.9.1](https://pub.dev/packages/pointycastle/versions/3.9.1) | [package license](tools/host-tests/upstream/LICENSE-pointycastle.txt), [Bouncy Castle notice](tools/host-tests/upstream/LICENSE-BouncyCastle.html) |
| Host crypto dependency (installed, not vendored) | libsodium-wrappers-sumo and libsodium-sumo, npm lockfile | ISC / included package notices |
| Host syntax checker (installed, not vendored) | TypeScript 4.9.5 | Apache-2.0 / included package notices |
| HarmonyOS test dependencies (installed, not vendored) | @ohos/hypium 1.0.25, @ohos/hamock 1.0.0 | Apache-2.0 / included package notices |
| Packaged C++ runtime | SDK-provided libc++_shared.so | [SDK LLVM notices](licenses/LLVM-NOTICE.txt), including Apache-2.0 with LLVM exceptions and retained component notices |

The canonical app icon is copied without a badge or redesign from
`mobile/apps/auth/assets/generation-icons/icon-light.png` at the pinned Ente
commit. SHA-256: `b8a64b00e9a72a3f2f7e1be8432595cccf5d7294cac0840d9f07bc7f3ac2881c`.
The icon does not grant affiliation or trademark endorsement.

The native dependency tree is retained with its licenses and source notices,
including upstream tests/build helpers; not every vendored source is compiled.
The CMake source selection and generated sodium version headers are part of this
port. Host fixtures are public known-answer vectors or deterministic synthetic
data, never real user credentials. See [TESTING.md](docs/TESTING.md).
