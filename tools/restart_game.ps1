# Dev helper: deploy the mod's scripts, close Hogwarts Legacy, wait until Steam itself has
# noticed the game is gone (relaunching earlier leaves Steam convinced the game is still
# running), then launch it again.
param([switch]$NoDeploy)

$root = Split-Path -Parent $PSScriptRoot
$win64 = "C:\Program Files (x86)\Steam\steamapps\common\Hogwarts Legacy\Phoenix\Binaries\Win64"
$steamLog = "C:\Program Files (x86)\Steam\logs\console_log.txt"

if (-not $NoDeploy) {
    Copy-Item (Join-Path $root "mod\Wandsong\Scripts\*.lua") (Join-Path $win64 "Mods\Wandsong\Scripts") -Force
}

$before = (Get-Content $steamLog).Count
if (Get-Process HogwartsLegacy -ErrorAction SilentlyContinue) {
    Stop-Process -Name HogwartsLegacy -Force -ErrorAction SilentlyContinue
    $gone = $false
    for ($i = 0; $i -lt 180; $i++) {
        Start-Sleep 1
        $new = Get-Content $steamLog | Select-Object -Skip $before
        if (-not (Get-Process HogwartsLegacy -ErrorAction SilentlyContinue) -and
            ($new -match 'Game process removed: AppID 990080')) { $gone = $true; break }
    }
    if (-not $gone) { "Steam never confirmed the game closed; not relaunching."; exit 1 }
}
Start-Sleep 3
Start-Process 'steam://rungameid/990080'
"relaunched"
