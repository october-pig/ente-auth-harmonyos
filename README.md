# Ente Auth for HarmonyOS

Native ArkTS / ArkUI HarmonyOS port of the open-source Ente Auth client.

**Unofficial community port. Not affiliated with or endorsed by Ente.**

**Alpha / Work in Progress — v0.1.0-alpha.** Core flows work, but this port does
not yet provide every feature of official Ente Auth. Keep a verified backup and
your account recovery information before trying it with important accounts.

## Screenshots

Screenshots will be added using synthetic accounts and codes. No real account
screenshots are included in this source distribution.

## Features and limitations

- Native Home, combined login and pushed Settings pages, search, tags, pinning
  and trash; readable OTP cards and system-aware light/dark surfaces.
- Ente login/session, online synchronization, offline storage and guarded
  offline-to-online migration.
- TOTP/HOTP support, manual entry, QR scanning and selected import/export formats.
- Chinese and English resources; localization and secondary-page styling remain
  incomplete. Language and theme rows do **not** yet offer in-app selection.
- App lock/biometric unlock, passkey completion, automated local backups and
  several account/security settings are deferred. Visible placeholders do not
  enable these features.
- **24-word recovery is unavailable:** the current BIP39 wordlist is incomplete.
  The hexadecimal recovery path exists but is not device-verified. Do not rely
  on this Alpha port as your only recovery method.

See the [feature matrix](docs/FEATURES.md) and [verification scope](docs/TESTING.md).
Tablet/2-in-1 layouts and arbitrary third-party devices are not verified.

## Build with DevEco Studio

1. Clone this repository and open its root directory in DevEco Studio.
2. Install a DevEco Studio distribution supporting **SDK 26 / Hvigor 26.0.0**,
   including HarmonyOS SDK and native C/C++ tools. Minimum app compatibility is
   **HarmonyOS 6.1.0 / API 23**; target SDK is **26.0.0**.
3. Sync the project / install ohpm dependencies. The included lockfile resolves
   the test libraries; libsodium source is vendored and needs no separate download.
4. Build the `entry` module with product `default`. Both `arm64-v8a` and `x86_64`
   native libraries are configured.
5. For a physical device, configure **your own** signing identity under
   **File > Project Structure > Project > Signing Configs**, then run from Studio.

The checked-in build configuration is intentionally unsigned. A successful HAP
build is not proof that the artifact can be installed on an arbitrary device.
Do not commit generated signing configuration or credentials.

See [BUILDING.md](docs/BUILDING.md) for exact CLI commands and signing references.

## Architecture

`entry/src/main/ets` contains ArkUI pages/components, account services, OTP and
crypto wrappers, guarded synchronization and storage adapters. HarmonyOS HUKS
protects stored key material. `entry/src/main/cpp` provides the N-API crypto bridge
and vendored libsodium. There is no Flutter or WebView application shell.

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for the important data/lifecycle boundaries.

## Tests

With Node.js 24 or newer, from the repository root:

```sh
npm ci --prefix tools/host-tests
npm test --prefix tools/host-tests
npm run check:arkts --prefix tools/host-tests
```

The host suite runs production logic against explicit platform models. It does
not prove real HUKS, database, camera or UI behavior. Build and device checks are
described separately in [TESTING.md](docs/TESTING.md).

## Upstream and license

Derivative of [official Ente](https://github.com/ente-io/ente), pinned to
[`3cc9103a3126de07f79a4465cf0b9922903de54b`](https://github.com/ente-io/ente/tree/3cc9103a3126de07f79a4465cf0b9922903de54b).
This port does not track the latest upstream automatically. The canonical Ente
Auth icon is retained unchanged; its use does not imply Ente endorsement.

Distributed under [AGPL-3.0](LICENSE). Third-party notices and source origins are
listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); retain them when
redistributing source or binaries.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md). Small changes with reproducible tests and
clear upstream references are welcome. Never include real OTP secrets, account
exports, recovery keys, session tokens or signing material in issues or patches.
See [SECURITY.md](SECURITY.md) before reporting a vulnerability. This Alpha port
has not undergone an independent security audit.

## Releases and installation

The first Alpha release is **v0.1.0-alpha**. Source builds with your own signing
identity are the supported path for physical-device testing. An optional
`*-unsigned.hap` download is a build artifact, **not a ready-to-install phone
package**. No universal sideload or AppGallery distribution claim is made.
See [release notes](docs/RELEASE_NOTES.md) for artifact names and limitations.
Downloads and checksums are provided on the
[GitHub prerelease page](https://github.com/october-pig/ente-auth-harmonyos/releases/tag/v0.1.0-alpha).
