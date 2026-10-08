# Dev helper: copy the mod (scripts and, with -Native, the built Lua C modules) into the game.
# Finds the game through Steam's library folders unless -Win64 is given.
#
#   powershell -ExecutionPolicy Bypass -File tools\deploy.ps1 [-Native] [-Win64 <path>]
#
# The game loads scripts at startup: restart it afterwards (never hot-reload while playing).
param([switch]$Native, [string]$Win64 = "", [string]$InputBridge = "", [string]$AudioBridge = "", [string]$LifetimeBridge = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (Get-Process -Name HogwartsLegacy -ErrorAction SilentlyContinue) {
    throw "Close Hogwarts Legacy normally before deploying. Updating a running game is not supported."
}

function Find-Win64 {
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { $steam = "C:\Program Files (x86)\Steam" }
    $libs = @($steam)
    $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libs += $m.Groups[1].Value -replace '\\\\', '\'
        }
    }
    foreach ($lib in $libs) {
        $p = Join-Path $lib "steamapps\common\Hogwarts Legacy\Phoenix\Binaries\Win64"
        if (Test-Path $p) { return $p }
    }
    throw "Hogwarts Legacy not found in any Steam library; pass -Win64"
}

if (-not $Win64) { $Win64 = Find-Win64 }
$mod = Join-Path $Win64 "Mods\Wandsong"
$scripts = Join-Path $mod "Scripts"
if (-not (Test-Path $scripts)) { throw "UE4SS mod folder missing: $scripts (run the installer first)" }
if ($InputBridge -and -not (Test-Path $InputBridge)) { throw "Input module missing: $InputBridge" }
if ($AudioBridge -and -not (Test-Path $AudioBridge)) { throw "Audio module missing: $AudioBridge" }
if ($LifetimeBridge -and -not (Test-Path $LifetimeBridge)) { throw "Lifetime module missing: $LifetimeBridge" }
if ($Native) {
    foreach ($dll in "prism_bridge.dll", "click_bridge.dll", "audio_bridge.dll", "input_bridge.dll", "lifetime_bridge.dll") {
        if (-not (Test-Path (Join-Path $root "native\build\Release\$dll"))) { throw "Build the native modules first: $dll is missing" }
    }
}

Copy-Item (Join-Path $root "mod\Wandsong\Scripts\*.lua") $scripts -Force
Write-Host "scripts -> $scripts"
if ($Native) {
    foreach ($dll in "prism_bridge.dll", "click_bridge.dll", "audio_bridge.dll", "input_bridge.dll", "lifetime_bridge.dll") {
        Copy-Item (Join-Path $root "native\build\Release\$dll") $scripts -Force
    }
    Write-Host "native modules -> $scripts"
}
if ($AudioBridge) {
    Copy-Item $AudioBridge (Join-Path $scripts "audio_bridge.dll") -Force
    Write-Host "audio module -> $scripts"
}
if ($InputBridge) {
    Copy-Item $InputBridge (Join-Path $scripts "input_bridge.dll") -Force
    Write-Host "input module -> $scripts"
}
if ($LifetimeBridge) {
    Copy-Item $LifetimeBridge (Join-Path $scripts "lifetime_bridge.dll") -Force
    Write-Host "lifetime module -> $scripts"
}
