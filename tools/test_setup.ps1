# Tests the one-file setup against fake game folders in %TEMP% (never the real game): install,
# update (a dropped file removed, the player's settings kept), uninstall, someone else's UE4SS
# backed up and put back, a hand-made copy, closed input, Enter, a wrong folder, no payload.
# Usage: powershell -ExecutionPolicy Bypass -File tools\test_setup.ps1 [-SetupExe <built setup>]
param([string]$SetupExe = (Join-Path (Split-Path -Parent $PSScriptRoot) "installer\build\Release\WandsongSetup.exe"))
$ErrorActionPreference = "Stop"
$env:WANDSONG_SETUP_QUIET = "1"
$env:WANDSONG_SETUP_OFFLINE = "1"   # deterministic: no online check
$testTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$base = Join-Path $testTempRoot ("WandsongSetupTest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $base | Out-Null
$fails = 0
function Check($cond, $what) { if ($cond) { Write-Output "ok   $what" } else { Write-Output "FAIL $what"; $script:fails++ } }

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
            $bw.Write([uint32]$name.Length); $bw.Write($name)
            $data = [System.IO.File]::ReadAllBytes($f.FullName)
            $bw.Write([uint64]$data.Length); $bw.Write($data)
        }
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("HWAPACK1"))
        $bw.Write($offset); $bw.Write([uint64]$files.Count)
    } finally { $bw.Close() }
}
function New-Payload($dir, $version, [switch]$WithOld) {
    New-Item -ItemType Directory -Force "$dir\Mods\Wandsong\Scripts", "$dir\Mods\Keybinds" | Out-Null
    Set-Content -Encoding ascii "$dir\dwmapi.dll" "loader $version"
    Set-Content -Encoding ascii "$dir\UE4SS.dll" "ue4ss"
    Set-Content -Encoding ascii "$dir\UE4SS-settings.ini" "[General]`r`nbUseUObjectArrayCache = true"
    Set-Content -Encoding ascii "$dir\Mods\mods.txt" "; Built-in keybinds, do not move up!`r`nKeybinds : 1"
    Set-Content -Encoding ascii "$dir\Mods\Keybinds\enabled.txt" ""
    Set-Content -Encoding ascii "$dir\Mods\Wandsong\enabled.txt" ""
    Set-Content -Encoding ascii "$dir\Mods\Wandsong\version.txt" $version
    Set-Content -Encoding ascii "$dir\Mods\Wandsong\Scripts\main.lua" "-- main $version"
    if ($WithOld) { Set-Content -Encoding ascii "$dir\Mods\Wandsong\Scripts\old.lua" "-- old" }
}
function New-Game($name) {
    $g = "$base\$name"
    New-Item -ItemType Directory -Force "$g\Phoenix\Binaries\Win64" | Out-Null
    Set-Content -Encoding ascii "$g\Phoenix\Binaries\Win64\HogwartsLegacy.exe" "game"
    return $g
}
function Run-Setup($exe, [string[]]$setupArgs) {
    # Input closed, never inherited: run from a shell whose input stays open, a question would
    # wait forever (it did once, and held the test folder locked).
    $out = $null | & $exe @setupArgs 2>&1 | Out-String
    return @{ code = $LASTEXITCODE; out = $out }
}

New-Payload "$base\p1" "0.4.0" -WithOld
New-Payload "$base\p2" "0.4.1"
Write-Pack $SetupExe "$base\p1" "$base\setup1.exe"
Write-Pack $SetupExe "$base\p2" "$base\setup2.exe"

# 1. A clean game: check, install, settings patched, record written.
$g = New-Game "clean"
$w = "$g\Phoenix\Binaries\Win64"
$r = Run-Setup "$base\setup1.exe" @("--check", "--game", $g)
Check ($r.code -eq 0 -and $r.out -match "isn't installed yet") "check on a clean game: $($r.out.Trim() -replace '\s+', ' ')"
$r = Run-Setup "$base\setup1.exe" @("--install", "--game", $g)
Check ($r.code -eq 0) "install exits 0"
Check ((Get-Content "$w\Mods\Wandsong\version.txt") -eq "0.4.0") "version.txt installed"
Check (Test-Path "$w\Mods\Wandsong\Scripts\old.lua") "all payload files installed"
Check ((Get-Content "$w\UE4SS-settings.ini" -Raw) -match "bUseUObjectArrayCache = false") "UE4SS settings patched"
Check ((Get-Content "$w\Mods\mods.txt" -Raw) -match "Wandsong : 1\r?\n; Built-in keybinds") "mods.txt enables the mod before Keybinds"
Check ((Get-Content "$w\Wandsong-manifest.txt")[0] -match "^# Wandsong \S+ installed files") "install record names the setup version"
Check (-not (Test-Path "$w\Wandsong-backup")) "no backup on a clean game"
Check (-not (Test-Path "$w\Wandsong-write-test.tmp")) "write test leaves nothing"

# 2. The player's settings, then an update that drops a file.
Set-Content -Encoding ascii "$w\Mods\Wandsong\keys.ini" "player keys"
Set-Content -Encoding ascii "$w\Mods\Wandsong\Scripts\keys.ini" "player keys 2"
$r = Run-Setup "$base\setup2.exe" @("--check", "--game", $g)
Check ($r.out -match "Wandsong 0.4.0 is installed") "check reports the installed version"
$r = Run-Setup "$base\setup2.exe" @("--install", "--game", $g)
Check ($r.code -eq 0 -and $r.out -match "is updated") "update exits 0 and says updated"
Check (-not (Test-Path "$w\Mods\Wandsong\Scripts\old.lua")) "a file the new version dropped is removed"
Check ((Get-Content "$w\Mods\Wandsong\keys.ini") -eq "player keys") "the player's settings stay"
Check ((Get-Content "$w\Mods\Wandsong\Scripts\keys.ini") -eq "player keys 2") "the player's keys stay"
Check ((Get-Content "$w\Mods\Wandsong\version.txt") -eq "0.4.1") "the new version is installed"
Check ((Get-Content "$w\Mods\Wandsong\Scripts\main.lua") -eq "-- main 0.4.1") "files are replaced"
$mods = (Get-Content "$w\Mods\mods.txt" | Where-Object { $_ -match "^Wandsong" }).Count
Check ($mods -eq 1) "mods.txt lists the mod once after an update"

# 3. Uninstall removes recorded files, preserving the player's unrecorded settings.
$r = Run-Setup "$base\setup2.exe" @("--uninstall", "--game", $g)
Check ($r.code -eq 0) "uninstall exits 0"
$left = @(Get-ChildItem -Recurse -File $w | ForEach-Object { $_.FullName.Substring($w.Length + 1) })
Check ($left.Count -eq 3 -and (Test-Path "$w\HogwartsLegacy.exe") -and
    (Get-Content "$w\Mods\Wandsong\keys.ini") -eq "player keys" -and
    (Get-Content "$w\Mods\Wandsong\Scripts\keys.ini") -eq "player keys 2") "uninstall preserves only the game and unrecorded settings: $($left -join ', ')"

# 4. Someone else's UE4SS: backed up, and put back on uninstall.
$g2 = New-Game "otherue4ss"
$w2 = "$g2\Phoenix\Binaries\Win64"
Set-Content -Encoding ascii "$w2\dwmapi.dll" "their loader"
New-Item -ItemType Directory -Force "$w2\Mods" | Out-Null
Set-Content -Encoding ascii "$w2\Mods\mods.txt" "TheirMod : 1"
$r = Run-Setup "$base\setup1.exe" @("--install", "--game", $g2)
Check ($r.code -eq 0 -and (Test-Path "$w2\Wandsong-backup\dwmapi.dll")) "their loader is backed up"
Check ((Get-Content "$w2\Mods\mods.txt" -Raw) -match "TheirMod : 1") "their mods.txt is kept and extended"
$r = Run-Setup "$base\setup1.exe" @("--uninstall", "--game", $g2)
Check ((Get-Content "$w2\dwmapi.dll") -eq "their loader") "their loader is put back"

# 5. A copy installed by hand has no ownership record: preserve every overwritten original.
$g3 = New-Game "devcopy"
$w3 = "$g3\Phoenix\Binaries\Win64"
New-Item -ItemType Directory -Force "$w3\Mods\Wandsong\Scripts" | Out-Null
Set-Content -Encoding ascii "$w3\dwmapi.dll" "our old loader"
Set-Content -Encoding ascii "$w3\Mods\Wandsong\Scripts\main.lua" "-- dev"
Set-Content -Encoding ascii "$w3\Mods\Wandsong\version.txt" "dev abc1234"
$r = Run-Setup "$base\setup1.exe" @("--check", "--game", $g3)
Check ($r.out -match "development build") "a development build is recognised"
$r = Run-Setup "$base\setup1.exe" @("--install", "--game", $g3)
Check ($r.code -eq 0 -and (Get-Content "$w3\Wandsong-backup\dwmapi.dll") -eq "our old loader") "updating a hand-made copy preserves its unrecorded loader"

# 6. Interactive with input closed: nothing changes.
$g4 = New-Game "eof"
$r = Run-Setup "$base\setup1.exe" @("--game", $g4)
Check (-not (Test-Path "$g4\Phoenix\Binaries\Win64\dwmapi.dll")) "closed input never counts as Enter"

# 7. Enter installs (piped).
$out = cmd /c "echo.| `"$base\setup1.exe`" --game `"$g4`"" 2>&1 | Out-String
Check (Test-Path "$g4\Phoenix\Binaries\Win64\dwmapi.dll") "Enter alone installs"

# 8. A folder that isn't the game.
$r = Run-Setup "$base\setup1.exe" @("--check", "--game", "$base")
Check ($r.code -ne 0 -and $r.out -match "doesn't contain Hogwarts Legacy") "a wrong folder is refused"

# 9. The setup with nothing appended falls back to a payload folder beside it, or says it's missing.
$r = Run-Setup $SetupExe @("--install", "--game", (New-Game "nopack"))
Check ($r.code -ne 0 -and $r.out -match "missing the mod's files") "no payload: refused"

Write-Output "$fails failed"
$resolvedTestBase = [System.IO.Path]::GetFullPath($base)
if (-not $resolvedTestBase.StartsWith($testTempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove a test folder outside the temporary directory: $resolvedTestBase"
}
Remove-Item -LiteralPath $resolvedTestBase -Recurse -Force
if ($fails -gt 0) { exit 1 }
exit 0
