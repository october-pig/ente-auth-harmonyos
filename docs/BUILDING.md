# Build and signing

## Requirements

- DevEco Studio with SDK 26 and Hvigor model/plugin 26.0.0; the preparation build
  uses DevEco Studio 26.0.0.821 and its bundled toolchain.
- Minimum compatibility: `6.1.0(23)`; target: `26.0.0`; runtime: HarmonyOS.
- Native toolchain (CMake/Ninja/Clang) from the SDK. The entry module builds
  `libentecrypto.so` for both `arm64-v8a` and `x86_64`.
- Node.js 24+ and npm for the independent host regression suite.
- Internet access to the public ohpm/npm registries for dependency installation.

Open the repository root in Studio and let it sync. No existing `.idea`, build
directory, local SDK path, private upstream checkout or signing file is needed.
DevEco Studio discovers the project from `build-profile.json5`, `hvigorfile.ts`,
`hvigor/hvigor-config.json5`, `oh-package.json5` and the entry module configuration.

## Command-line verification

Use a terminal with the **installed DevEco Studio** `ohpm` and `hvigorw` commands
on PATH (Studio supplies them; a wrapper binary is not vendored here). On Windows
these are `tools/ohpm/bin/ohpm.bat` and `tools/hvigor/bin/hvigorw.bat` under your
own Studio installation. Configure the SDK through Studio or its supported local
SDK configuration. Never copy another developer's `local.properties`.

For a Windows terminal outside Studio, set the toolchain variables for your own
installation before invoking Hvigor. `DEVECO_SDK_HOME` is the SDK root containing
`default`, not the `default` subdirectory. For example, after setting
`$studioRoot` to your local installation directory:

```powershell
$env:DEVECO_SDK_HOME = Join-Path $studioRoot 'sdk'
$env:JAVA_HOME = Join-Path $studioRoot 'jbr'
$env:Path = (Join-Path $studioRoot 'jbr/bin') + ';' + (Join-Path $studioRoot 'tools/ohpm/bin') + ';' + (Join-Path $studioRoot 'tools/hvigor/bin') + ';' + $env:Path
```

```sh
ohpm install --all
npm ci --prefix tools/host-tests
npm test --prefix tools/host-tests
npm run check:arkts --prefix tools/host-tests
hvigorw clean --no-daemon
hvigorw --mode module -p product=default -p module=entry@default -p buildMode=release assembleHap --no-daemon
hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug UnitTestBuild --no-daemon
```

Run these Hvigor tasks **sequentially**; concurrent builds in one tree can race
on generated resources. The unsigned HAP is under
`entry/build/default/outputs/default/`. Use Studio Code Linter, or the optional
DevEco CLI `devecocli check lint`, with the checked-in `code-linter.json5`.
`devecocli build` is also an optional wrapper; it is not a source dependency.

## Signing and installation

The repository has no signing identity. For your physical device, open
**File > Project Structure > Project > Signing Configs**, sign in to your own
Huawei developer account and configure automatic signing for your device (or
use the supported manual signing process). You may need your own bundle name
and registered application according to the selected signing model.

Signing edits `build-profile.json5` locally. Do not commit its personal paths,
encrypted passwords, certificate/profile settings, `.p12` keys or `.p7b` profiles.
Review `git diff` before committing. Keep your signing identity consistent for
updates; do not uninstall an existing authenticator as a shortcut around a
signature mismatch without first securing your data.

Huawei documents that debug-signed HAP installation is restricted to device
UDIDs in the debug Profile. A package working on the maintainer's device is not
evidence of installation on anyone else's phone. This project has no verified
universal-install release package. An unsigned artifact needs an appropriate
supported signing/distribution process before physical-device installation.

Official references (checked 2026-09-29):

- [Automatic signing](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-auto)
- [Manual signing](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing-manual)
- [Huawei release FAQ: HAP, APP and device restrictions](https://developer.huawei.com/consumer/cn/doc/app/agc-help-releasefaq-0000001110342644)
