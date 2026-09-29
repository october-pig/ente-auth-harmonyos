# Feature status

Status reflects this Alpha source, not all capabilities of official Ente Auth.
Working means implemented, with the evidence limits in [TESTING.md](TESTING.md).

| Area | Status | Scope / limitation |
| --- | --- | --- |
| Native Home / Login / Settings | Working | HDS navigation, search, tags, pinning, trash, busy login feedback; secondary pages still need polish |
| Ente account / session | Working | Password/SRP, email-code fallback, supported 2FA, persistent session and expiry/logout handling; passkey completion excluded |
| TOTP / HOTP | Working | Calculation and supported code flows; host vectors cover algorithms, not every provider/device |
| Online synchronization | Working | Remote differences plus pending local writes; account-revision guarded |
| Offline mode | Working | Local encrypted storage; no account required |
| Offline-to-online migration | Working | Reconciliation, retry states and evidence-based source cleanup |
| QR / manual entry | Working | ScanKit paths and otpauth input; device capabilities vary |
| Import | Partial | Plain otpauth / Ente JSON, encrypted Ente export, Google migration, Bitwarden, LastPass and Raivo parsers; 2FAS, Aegis, andOTP, Proton and OTP Auth deferred |
| Export | Working | Plain/encrypted Ente export and supported selection flows; protect plaintext exports |
| Language | Partial | Chinese base and English resources; remaining strings need localization; selector planned |
| Theme | Partial | System-aware light/dark resources; in-app override and secondary-page consistency planned |
| Hide codes | Working | Persistent setting updates visible cards; not an app lock |
| App lock / biometrics | Planned | No enforced UI lock or biometric unlock; HUKS key protection is a separate mechanism |
| Passkeys | Planned | Challenge completion unsupported; app explains the limitation |
| Account recovery | Partial | BIP39 wordlist contains empty placeholders, so 24-word recovery does not work. Hexadecimal recovery exists but is not device-verified. Do not rely on this port as your only recovery path. |
| Automated local backups | Planned | Settings placeholder; manual export available |
| Account/security management | Planned | Change email/password, view recovery key, delete account, manage active sessions and email-verification settings are deferred rows |
| Tablets / 2-in-1 | Partial | Manifest permits these types; no device acceptance evidence |

Account creation lacks the same real-account coverage as ordinary login/sync.
The passing host suite does not establish mnemonic recovery support. Password derivation may
still block UI animation. No background polling or instant cross-device push
guarantee is made.
