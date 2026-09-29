# Contributing

This is an unofficial Alpha port. Read the feature matrix and build instructions
before proposing a feature; deferred Settings rows are intentional, not working
security controls. Use the pinned Ente source for product behavior and current
Huawei documentation/installed SDK for platform behavior.

Keep changes focused. Explain the user-visible problem, implementation and actual
verification. Run host regressions, syntax/import checks, a clean HAP build,
UnitTestBuild and lint for affected code. Native/UI changes need device feedback;
state clearly when that feedback is unavailable.

Use synthetic fixtures only. Never attach real authenticator exports, account
emails, QR payloads, recovery keys, session tokens, signing files or device dumps.
Preserve copyright/license notices. Do not casually alter authentication, crypto,
sync formats or storage cleanup to simplify presentation.

Report UI issues with OS/SDK information and redacted or synthetic examples.
For sensitive issues, follow [SECURITY.md](SECURITY.md), not a public issue.
