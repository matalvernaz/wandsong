# Builds Wandsong and assembles dist\Wandsong-<version>.zip.
#
# Needs: Visual Studio 2022 Build Tools, CMake, GitHub CLI (gh) for fetching dependencies.
# Usage: powershell -ExecutionPolicy Bypass -File tools\build_release.ps1

param([string]$Version = "0.1.0")
$ErrorActionPreference = "Stop"

$root  = Split-Path -Parent $PSScriptRoot
$third = Join-Path $root "third_party"
$dist  = Join-Path $root "dist"
$stage = Join-Path $dist "Wandsong"

$PrismTag = "v0.18.3"
$UE4SSTag = "v3.0.1"

function Fetch-Prism {
    $dir = Join-Path $third "prism"
    if (Test-Path (Join-Path $dir "include\prism.h")) { return }
    New-Item -ItemType Directory -Force $third | Out-Null
    gh release download $PrismTag -R ethindp/prism -p prism-windows-x64.zip -D $third --clobber
    Expand-Archive (Join-Path $third "prism-windows-x64.zip") -DestinationPath $dir -Force
}

function Fetch-UE4SS {
    $zip = Join-Path $third "UE4SS_$UE4SSTag.zip"
    if (-not (Test-Path $zip)) {
        gh release download $UE4SSTag -R UE4SS-RE/RE-UE4SS -p "UE4SS_$UE4SSTag.zip" -D $third --clobber
    }
    $dir = Join-Path $third "ue4ss"
    if (-not (Test-Path (Join-Path $dir "dwmapi.dll"))) { Expand-Archive $zip -DestinationPath $dir -Force }
    $lic = Join-Path $third "UE4SS-LICENSE.txt"
    if (-not (Test-Path $lic)) {
        gh api repos/UE4SS-RE/RE-UE4SS/contents/LICENSE -H "Accept: application/vnd.github.raw" | Set-Content -Encoding utf8 $lic
    }
}

function Build($name) {
    $src = Join-Path $root $name
    cmake -S $src -B (Join-Path $src "build") -G "Visual Studio 17 2022" -A x64 | Out-Null
    cmake --build (Join-Path $src "build") --config Release | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "build of $name failed" }
}

Fetch-Prism
Fetch-UE4SS
Build "helper"
Build "installer"
Build "native"

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
$payload = Join-Path $stage "payload"
New-Item -ItemType Directory -Force (Join-Path $payload "Mods") | Out-Null

# Installer at the top, everything that goes into the game's Win64 folder under payload\.
Copy-Item (Join-Path $root "installer\build\Release\WandsongSetup.exe") $stage
Copy-Item (Join-Path $third "prism\dynamic\release\bin\prism.dll") $stage

$ue = Join-Path $third "ue4ss"
Copy-Item (Join-Path $ue "dwmapi.dll"), (Join-Path $ue "UE4SS.dll") $payload
Copy-Item (Join-Path $root "ue4ss\UE4SS-settings.ini") $payload
Copy-Item (Join-Path $root "ue4ss\mods.txt") (Join-Path $payload "Mods")
Copy-Item -Recurse (Join-Path $ue "Mods\shared"), (Join-Path $ue "Mods\Keybinds") (Join-Path $payload "Mods")

$mod = Join-Path $payload "Mods\Wandsong"
Copy-Item -Recurse (Join-Path $root "mod\Wandsong") (Join-Path $payload "Mods")
New-Item -ItemType Directory -Force (Join-Path $mod "helper") | Out-Null
Copy-Item (Join-Path $root "helper\build\Release\wandsong_helper.exe") (Join-Path $mod "helper")
Copy-Item (Join-Path $third "prism\dynamic\release\bin\prism.dll") (Join-Path $mod "helper")
# In-process speech and clicks (Lua C modules) sit beside the scripts that require them.
$scripts = Join-Path $mod "Scripts"
Copy-Item (Join-Path $root "native\build\Release\prism_bridge.dll"), (Join-Path $root "native\build\Release\click_bridge.dll"), (Join-Path $root "native\build\Release\audio_bridge.dll"), (Join-Path $root "native\build\Release\input_bridge.dll") $scripts
Copy-Item (Join-Path $third "prism\dynamic\release\bin\prism.dll") $scripts

# Docs and licenses.
Copy-Item (Join-Path $root "README.md"), (Join-Path $root "LICENSE") $stage
$lic = Join-Path $stage "licenses"
New-Item -ItemType Directory -Force $lic | Out-Null
Copy-Item (Join-Path $third "UE4SS-LICENSE.txt") (Join-Path $lic "UE4SS-MIT.txt")
Copy-Item (Join-Path $third "prism\LICENSES\prism\mpl-2.0.txt") (Join-Path $lic "Prism-MPL-2.0.txt")
Copy-Item (Join-Path $third "prism\NOTICE") (Join-Path $lic "Prism-NOTICE.txt")
Copy-Item (Join-Path $third "prism\LICENSES\nvdaController\lgpl-2.1.txt") (Join-Path $lic "NVDA-controller-LGPL-2.1.txt")
Copy-Item (Join-Path $root "native\lua-5.4.4\LICENSE") (Join-Path $lic "Lua-MIT.txt")

$zip = Join-Path $dist "Wandsong-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Output "Built $zip"
