# Security

This is Alpha software and has not received an independent security audit.
Automated tests and selected device checks are useful evidence, not a security
certification. App lock/biometric unlock is not implemented; hiding codes does
not prevent access to the app. Keep verified backups and recovery information.
The current BIP39 wordlist is incomplete: 24-word mnemonic recovery is unavailable.
Do not rely on this Alpha client as your only recovery tool.

Do not post credentials, OTP seeds, recovery phrases, account exports, signed
debug profiles or exploit details publicly. Use GitHub's private vulnerability
reporting interface **if enabled** on this repository. If unavailable, ask the
maintainer for a private reporting channel without sending sensitive details.
Do not assume Ente supports or maintains this port.

Contributors must keep signing configuration local, review staged files, and
use synthetic test accounts/keys. A discovered real credential must be treated
as potentially exposed and handled by its owner; deleting a source line does
not establish that the credential is safe.
