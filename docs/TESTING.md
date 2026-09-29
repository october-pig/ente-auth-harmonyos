# Verification and reproducible tests

## Run locally

```sh
npm ci --prefix tools/host-tests
npm test --prefix tools/host-tests
npm run check:arkts --prefix tools/host-tests
```

`prepare.mjs` copies production ArkTS to a generated test directory and records
source hashes. Node's loader supplies explicit HarmonyOS platform models.
The syntax/import checker uses a locked local TypeScript dependency and fails if
it is missing; ArkUI declarative files need the actual ArkTS compiler.
Native HUKS/storage/camera/UI semantics cannot be established by host models.

Fixtures under `entry/src/test/fixtures` contain synthetic/public test secrets,
not accounts. `tools/host-tests/gen-fixtures.mjs` documents their generation.
Randomized encryption fixtures are checked by decryption where appropriate.
Do not replace these with real exports or QR data.

## Preparation evidence — 2026-09-29

The public source tree is verified independently with freshly installed project
and host dependencies; no private checkout dependencies or build outputs are copied.

| Check | Result / boundary |
| --- | --- |
| HOST regressions | 486/486 PASS, 81 suites, 20 files |
| Syntax/import check | 52 parsed files, zero errors/unresolved imports; 11 ArkUI files delegated to real compilation |
| Clean Release HAP | PASS, unsigned; target API 26, compatible API 23 |
| UnitTestBuild | PASS; compilation is not test execution |
| Lint | 0 errors / 16 advisories |
| Native ABI packaging | Both arm64-v8a and x86_64 contain libentecrypto.so and libc++_shared.so |
| Public artifact device installation | Not run; unsigned artifact is not a phone-installable package |

Earlier development-device observations on a Mate 80 Pro Max cover ordinary
login/session restart, cloud interoperability, offline storage/migration, selected
export/import flows and reported Home/Settings fixes. They are evidence for
those flows on that device, not a new test of the public artifact or all devices.
Synthetic fault scenarios remain host evidence. No independent security audit
or universal installation claim is made.

## Known coverage gaps

The BIP39 wordlist is empty placeholder data; 24-word recovery is unsupported,
despite recovery-related code existing. The current suite does not establish
mnemonic recovery correctness. Hexadecimal recovery and account creation need
dedicated device coverage. UI rendering, keyboard behavior, responsiveness,
tablets/2-in-1 and signing on another person's device require human/device checks.

For SDK checks and native builds, use [BUILDING.md](BUILDING.md), then run Studio
tests explicitly where appropriate. Preserve the distinction between compiling
test code, executing host tests and executing device tests.
