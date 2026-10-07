# Run Lua on the game thread without sending a key: the script is handed to the mod as
# dev_request.lua, which runs it within a second (never during a load) and writes the result
# to dev_result.txt. Read-only probes only; never register hooks from a request.
#
#   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -File tools\probe_statues.lua
#   powershell -ExecutionPolicy Bypass -File tools\dev.ps1 -Code "return 1 + 1"
param([string]$File = "", [string]$Code = "", [int]$Wait = 15, [string]$Win64 = "")
$ErrorActionPreference = "Stop"
if (-not $Win64) {
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { $steam = "C:\Program Files (x86)\Steam" }
    $Win64 = Join-Path $steam "steamapps\common\Hogwarts Legacy\Phoenix\Binaries\Win64"
}
$mod = Join-Path $Win64 "Mods\Wandsong"
if (-not (Test-Path $mod)) { throw "Mod folder not found: $mod" }
if ($File) { $Code = Get-Content -Raw -Encoding UTF8 $File }
if (-not $Code) { throw "Give -File or -Code" }
if (-not (Get-Process -Name HogwartsLegacy -ErrorAction SilentlyContinue)) { throw "Hogwarts Legacy is not running." }

$request = Join-Path $mod "dev_request.lua"
$result = Join-Path $mod "dev_result.txt"
$tmp = Join-Path $mod "dev_request.tmp"
Remove-Item $result -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($tmp, $Code, (New-Object Text.UTF8Encoding $false))
Move-Item $tmp $request -Force   # the mod never sees a half-written request

$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.Elapsed.TotalSeconds -lt $Wait) {
    if (Test-Path $result) {
        Start-Sleep -Milliseconds 100
        Get-Content -Raw -Encoding UTF8 $result
        exit 0
    }
    Start-Sleep -Milliseconds 200
}
Remove-Item $request -ErrorAction SilentlyContinue
Write-Output "No result after $Wait s (loading, a menu that stops the dispatcher, or the mod is not running)."
exit 1
