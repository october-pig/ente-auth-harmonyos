# Test reference source

`srp/srp6_standard_groups.dart` is a verbatim copy of
`lib/srp/srp6_standard_groups.dart` from the published
[pointycastle 3.9.1 package](https://pub.dev/packages/pointycastle/versions/3.9.1).
It is read as test data, not compiled or shipped in the application.

SHA-256: `c092e1cbf7f7ea07955cd70cc8a9228b7342504a399fed72eb28527a05ea39e1`.
The file was compared byte-for-byte with the published 3.9.1 archive during
source preparation. The corresponding license and Bouncy Castle notice are
included in this directory.

SRP tests derive the expected RFC 5054 group from this reference instead of a
second hand-transcription. No private upstream checkout is needed to run tests.
