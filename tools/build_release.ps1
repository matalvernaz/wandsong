# Builds Wandsong and its one-file setup: dist\WandsongSetup-<version>.exe carries
# UE4SS and the mod appended to the setup program, so a player downloads one file and runs it.
# Also dist\Wandsong-<version>.zip with that file, the README and the licenses.
#
# Needs: Visual Studio 2022 Build Tools, CMake, GitHub CLI (gh) for fetching dependencies.
# Usage: powershell -ExecutionPolicy Bypass -File tools\build_release.ps1 -Version 0.4.0

param([string]$Version = "0.4.0")
$ErrorActionPreference = "Stop"

$root  = Split-Path -Parent $PSScriptRoot
$third = Join-Path $root "third_party"
$dist  = Join-Path $root "dist"
$stage = Join-Path $dist "Wandsong"
$payload = Join-Path $dist "payload"

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

function Build($name, [string[]]$extra = @()) {
    $src = Join-Path $root $name
    cmake -S $src -B (Join-Path $src "build") -G "Visual Studio 17 2022" -A x64 @extra | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "configuring $name failed" }
    cmake --build (Join-Path $src "build") --config Release | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "build of $name failed" }
}

# Appends every file under $dir to a copy of the setup program: per file a uint32 path length,
# the path (UTF-8, relative to the game's Win64 folder), a uint64 size and the bytes; then the
# footer the setup looks for: "HWAPACK1", the uint64 offset of the first file, the uint64 count.
function Write-Pack($exeIn, $dir, $exeOut) {
    Copy-Item $exeIn $exeOut -Force
    $dir = (Resolve-Path $dir).Path.TrimEnd('\')
    $files = @(Get-ChildItem -Recurse -File $dir | Sort-Object FullName)
    $fs = [System.IO.File]::Open($exeOut, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $offset = [uint64]$fs.Position
        foreach ($f in $files) {
            $name = [System.Text.Encoding]::UTF8.GetBytes($f.FullName.Substring($dir.Length + 1))
            $bw.Write([uint32]$name.Length)
            $bw.Write($name)
            $data = [System.IO.File]::ReadAllBytes($f.FullName)
            $bw.Write([uint64]$data.Length)
            $bw.Write($data)
        }
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("HWAPACK1"))
        $bw.Write($offset)
        $bw.Write([uint64]$files.Count)
    } finally {
        $bw.Close()
    }
    return $files.Count
}

Fetch-Prism
Fetch-UE4SS
Build "helper"
Build "installer" @("-DWANDSONG_VERSION=$Version")
Build "native"

# Everything that goes into the game's Win64 folder, as it will be laid out there.
if (Test-Path $payload) { Remove-Item -Recurse -Force $payload }
New-Item -ItemType Directory -Force (Join-Path $payload "Mods") | Out-Null
$ue = Join-Path $third "ue4ss"
Copy-Item (Join-Path $ue "dwmapi.dll"), (Join-Path $ue "UE4SS.dll") $payload
Copy-Item (Join-Path $root "ue4ss\UE4SS-settings.ini") $payload
Copy-Item (Join-Path $root "ue4ss\mods.txt") (Join-Path $payload "Mods")
Copy-Item -Recurse (Join-Path $ue "Mods\shared"), (Join-Path $ue "Mods\Keybinds") (Join-Path $payload "Mods")

# The mod: its scripts and UE4SS's enabled marker only (never a checkout's logs or settings).
$mod = Join-Path $payload "Mods\Wandsong"
$scripts = Join-Path $mod "Scripts"
New-Item -ItemType Directory -Force $scripts, (Join-Path $mod "helper") | Out-Null
Copy-Item (Join-Path $root "mod\Wandsong\enabled.txt") $mod
Copy-Item (Join-Path $root "mod\Wandsong\Scripts\*.lua") $scripts
Set-Content -Encoding ascii (Join-Path $mod "version.txt") $Version
Copy-Item (Join-Path $root "helper\build\Release\wandsong_helper.exe") (Join-Path $mod "helper")
Copy-Item (Join-Path $third "prism\dynamic\release\bin\prism.dll") (Join-Path $mod "helper")
# In-process speech, clicks, sound, input and the deletion record (Lua C modules) sit beside the
# scripts that require them.
foreach ($dll in "prism_bridge.dll", "click_bridge.dll", "audio_bridge.dll", "input_bridge.dll", "lifetime_bridge.dll") {
    Copy-Item (Join-Path $root "native\build\Release\$dll") $scripts
}
Copy-Item (Join-Path $third "prism\dynamic\release\bin\prism.dll") $scripts

# Licenses travel inside the setup (installed with the mod) and beside it.
$lic = Join-Path $mod "licenses"
New-Item -ItemType Directory -Force $lic | Out-Null
Copy-Item (Join-Path $root "LICENSE") (Join-Path $lic "Wandsong-LICENSE.txt")
Copy-Item (Join-Path $third "UE4SS-LICENSE.txt") (Join-Path $lic "UE4SS-MIT.txt")
Copy-Item (Join-Path $third "prism\LICENSES\prism\mpl-2.0.txt") (Join-Path $lic "Prism-MPL-2.0.txt")
Copy-Item (Join-Path $third "prism\NOTICE") (Join-Path $lic "Prism-NOTICE.txt")
Copy-Item (Join-Path $third "prism\LICENSES\nvdaController\lgpl-2.1.txt") (Join-Path $lic "NVDA-controller-LGPL-2.1.txt")
Copy-Item (Join-Path $root "native\lua-5.4.4\LICENSE") (Join-Path $lic "Lua-MIT.txt")

# The one-file setup.
$setup = Join-Path $dist "WandsongSetup-$Version.exe"
$count = Write-Pack (Join-Path $root "installer\build\Release\WandsongSetup.exe") $payload $setup
Write-Output "Built $setup ($count files)"

# The zip: the setup, the README and the licenses.
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $setup (Join-Path $stage "WandsongSetup.exe")
Copy-Item (Join-Path $root "README.md"), (Join-Path $root "LICENSE") $stage
Copy-Item -Recurse $lic (Join-Path $stage "licenses")
$zip = Join-Path $dist "Wandsong-$Version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Output "Built $zip"
