# v0.1.0-alpha — release draft

**Alpha / Work in Progress. Unofficial community HarmonyOS port, not affiliated
with or endorsed by Ente.** This document prepares a release; it does not assert
that a GitHub Release has been published.

Native Home/Login/Settings, Ente account sessions, OTP, cloud sync, offline mode,
migration, QR and selected import/export flows are included. See [FEATURES.md](FEATURES.md)
for incomplete features, especially missing BIP39 mnemonic recovery, app lock,
passkeys and in-app language/theme selection.

## Proposed assets

- `ente-auth-harmonyos-v0.1.0-alpha-source.zip`: the reviewed public source tree.
- `ente-auth-harmonyos-v0.1.0-alpha-unsigned.hap`: optional compiled unsigned HAP,
  **not directly installable on a physical phone**.
- `SHA256SUMS.txt`: checksums of those exact artifacts.

The HAP targets HarmonyOS SDK 26.0.0 with compatibility 6.1.0(23), and packages
`libentecrypto.so` for arm64-v8a and x86_64. It contains no developer debug signing
profile or private signing identity. No separate unregistered-device installation
has been verified. Build from source and configure your own supported signing
identity as described in [BUILDING.md](BUILDING.md).

Publish the public initial commit/tree identity alongside the exact checksums.
Do not link a private development commit as the only corresponding source.
Include full matching source and license notices with any binary distribution.
HOST regression evidence is 486/486; unsigned compilation does not prove device
installation, UI acceptance or all account-recovery paths.
