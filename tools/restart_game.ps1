# Dev helper: deploy the mod's scripts, close Hogwarts Legacy, wait until Steam itself has
# noticed the game is gone (relaunching earlier leaves Steam convinced the game is still
# running), then launch it again.
param([switch]$NoDeploy, [switch]$Native)

$root = Split-Path -Parent $PSScriptRoot
$win64 = "C:\Program Files (x86)\Steam\steamapps\common\Hogwarts Legacy\Phoenix\Binaries\Win64"
$steamLog = "C:\Program Files (x86)\Steam\logs\console_log.txt"

if (-not $NoDeploy) {
    Copy-Item (Join-Path $root "mod\Wandsong\Scripts\*.lua") (Join-Path $win64 "Mods\Wandsong\Scripts") -Force
}

$before = (Get-Content $steamLog).Count
if (Get-Process HogwartsLegacy -ErrorAction SilentlyContinue) {
    Stop-Process -Name HogwartsLegacy -Force -ErrorAction SilentlyContinue
    # A deliberate kill isn't a crash: don't let the world layer's crash fuse trip.
    Remove-Item (Join-Path $win64 "Mods\Wandsong\Scripts\world_active.flag") -ErrorAction SilentlyContinue
    $gone = $false
    for ($i = 0; $i -lt 180; $i++) {
        Start-Sleep 1
        $new = Get-Content $steamLog | Select-Object -Skip $before
        if (-not (Get-Process HogwartsLegacy -ErrorAction SilentlyContinue) -and
            ($new -match 'Game process removed: AppID 990080')) { $gone = $true; break }
    }
    if (-not $gone) { "Steam never confirmed the game closed; not relaunching."; exit 1 }
}
# The game holds the native modules open while it runs: copy them once it has closed.
if ($Native) {
    foreach ($dll in "prism_bridge.dll", "click_bridge.dll", "audio_bridge.dll", "input_bridge.dll", "lifetime_bridge.dll") {
        try { Copy-Item (Join-Path $root "native\build\Release\$dll") (Join-Path $win64 "Mods\Wandsong\Scripts") -Force -ErrorAction Stop }
        catch { "native copy failed: $dll ($($_.Exception.Message)); not relaunching."; exit 1 }
    }
}
Start-Sleep 3
Start-Process 'steam://rungameid/990080'
"relaunched"
