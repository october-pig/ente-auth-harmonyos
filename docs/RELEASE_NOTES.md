# v0.1.0-alpha

**Alpha / Work in Progress. Unofficial community HarmonyOS port, not affiliated
with or endorsed by Ente.** This is an Alpha prerelease, not a production-ready
or independently audited authenticator.

Native Home/Login/Settings, Ente account sessions, OTP, cloud sync, offline mode,
migration, QR and selected import/export flows are included. See [FEATURES.md](FEATURES.md)
for incomplete features, especially missing BIP39 mnemonic recovery, app lock,
passkeys and in-app language/theme selection.

## Release assets

- `ente-auth-harmonyos-v0.1.0-alpha-unsigned.hap`: compiled unsigned HAP,
  **not directly installable on a physical phone**.
- `SHA256SUMS.txt`: the SHA-256 of that exact HAP.

GitHub generates the source ZIP and tar.gz from the release tag; no duplicate
source archive is uploaded. The matching source contains AGPL and third-party
notices, including the packaged C++ runtime notices.

The HAP targets HarmonyOS SDK 26.0.0 with compatibility 6.1.0(23), and packages
`libentecrypto.so` for arm64-v8a and x86_64. It contains no developer debug signing
profile or private signing identity. No separate unregistered-device installation
has been verified. Build from source and configure your own supported signing
identity as described in [BUILDING.md](BUILDING.md).

The [GitHub release](https://github.com/october-pig/ente-auth-harmonyos/releases/tag/v0.1.0-alpha)
records the exact public source commit, current verification results and HAP hash.
Unsigned compilation does not prove device installation, UI acceptance or all
account-recovery paths. In particular, **24-word BIP39 recovery is unavailable**;
hexadecimal recovery lacks complete device verification. App lock/biometric
unlock and passkey completion are not implemented. Some imports, in-app language/
theme selection and secondary-page localization/UI work remain incomplete.
