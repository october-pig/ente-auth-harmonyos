# Architecture and data boundaries

- `entry/src/main/ets/pages`, `components`: native ArkUI/HDS presentation.
  Router owns the navigation stack; UI state must not become a second authority
  for account state or persistence.
- `account`, `services`, `network`: Ente account/session orchestration, SRP and
  HTTP protocol behavior. Authentication is aligned with the pinned upstream,
  including email-code/2FA fallback rather than a separate custom protocol.
- `otp`, `models`: OTP algorithms, URI parsing and code metadata.
- `store`, `storage`: online/offline encrypted records and HUKS-backed secure
  configuration. Storage ownership matters across account switches and logout.
- `crypto` plus `entry/src/main/cpp`: ArkTS wrappers and N-API bridge to libsodium
  for upstream-compatible cryptographic operations. Host shims never ship in the app.
- `resources` and `tools/gen-appstrings.mjs`: Chinese base / English strings;
  generated typed resource accessors must be kept consistent with resources.

## Synchronization

Online startup, foregrounding, successful login and code edits trigger cloud
checks. Home also checks for offline migration; an empty offline table can still
cause an ordinary cloud sync. The migration banner represents actual offline
source processing, not every network request. There is no OTP-timer network sync.

Sync runs serially, coalescing concurrent requests. It pulls remote differences,
preserves pending local changes and uploads pending rows. Timestamp boundary
overlap avoids skipping rows that share a timestamp. Account revision checks
prevent late work from mutating a new session.

Offline migration reconciles with server evidence, retaining source data until
upload and local acknowledgement are verified. Ambiguous outcomes must not be
treated as success. Logout/session expiry must drain or invalidate admitted work
and preserve unsynchronized data. A backup does not itself authorize a logout
that would discard pending changes.

## Storage and tests

HUKS wraps sensitive key material stored through the secure-storage adapter.
Ordinary preferences and secure values share underlying storage concerns: a
broad preferences clear must not bypass the ownership/cleanup rules. System
backup configuration is not a substitute for an implemented local-backup feature.

Host tests model the platform and test failure/lifecycle boundaries. They do not
prove the real keystore, database transaction timing or renderer. Change these
boundaries only with explicit upstream/SDK evidence and focused regressions.
