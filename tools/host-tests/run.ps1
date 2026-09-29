# Host parity harness launcher.
# Runs the REAL ArkTS production sources under Node (type-stripped) against
# upstream-derived fixtures. Nothing in entry/src is modified.
#
#   pwsh -File tools/host-tests/run.ps1
#
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    if (-not (Test-Path 'node_modules/libsodium-wrappers-sumo')) {
        Write-Host '[host-tests] installing dependencies...'
        npm ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    node prepare.mjs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    node --experimental-transform-types --no-warnings --import ./register.mjs run.mjs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
