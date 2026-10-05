# Dev helper: copy the mod (scripts and, with -Native, the built Lua C modules) into the game.
# Finds the game through Steam's library folders unless -Win64 is given.
#
#   powershell -ExecutionPolicy Bypass -File tools\deploy.ps1 [-Native] [-Win64 <path>]
#
# The game loads scripts at startup: restart it afterwards (never hot-reload while playing).
param([switch]$Native, [string]$Win64 = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

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

Copy-Item (Join-Path $root "mod\Wandsong\Scripts\*.lua") $scripts -Force
Write-Host "scripts -> $scripts"
if ($Native) {
    foreach ($dll in "prism_bridge.dll", "click_bridge.dll", "audio_bridge.dll") {
        Copy-Item (Join-Path $root "native\build\Release\$dll") $scripts -Force
    }
    Write-Host "native modules -> $scripts"
}
