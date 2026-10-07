# Run from the source checkout after git pull. Updates an existing installation.
# Never launches or stops the game, sends keys, or changes player settings.
param([string]$Win64 = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (Get-Process -Name HogwartsLegacy -ErrorAction SilentlyContinue) {
    throw "Close Hogwarts Legacy normally, then run this update again."
}
Push-Location $root
try {
    & python tools\run_tests.py
    if ($LASTEXITCODE -ne 0) { throw "Tests failed. Nothing has been deployed." }
    & cmake --build native\build-tests --config Release --target input_bridge
    if ($LASTEXITCODE -ne 0) { throw "Input module build failed. Nothing has been deployed." }
    $inputDll = Join-Path $root "native\build-tests\Release\input_bridge.dll"
    if (-not (Test-Path $inputDll)) { throw "Built input module was not found: $inputDll" }
    & "$PSScriptRoot\deploy.ps1" -Win64 $Win64 -InputBridge $inputDll
    $revision = & git rev-parse --short HEAD
    Write-Host "Wandsong $revision deployed. Start the game normally."
    Write-Host "Test steps and log checks: docs\TESTING_ON_GAME_PC.md"
} finally {
    Pop-Location
}
