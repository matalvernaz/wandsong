# Dev helper: press keys in the game, then print what the mod said and which screens opened.
# Usage: drive.ps1 -Keys "f","rbr" [-Wait 2500] [-Lines 8]
param([string[]]$Keys, [int]$Wait = 2500, [int]$Lines = 8, [switch]$Probe, [switch]$Post)
# powershell -File passes "a,b" as one string: split it.
$Keys = @($Keys | ForEach-Object { $_ -split "," } | Where-Object { $_ })

$log = "C:\Program Files (x86)\Steam\steamapps\common\Hogwarts Legacy\Phoenix\Binaries\Win64\UE4SS.log"
$before = (Get-Content $log -Encoding UTF8).Count
if (-not $Keys) { Start-Sleep -Milliseconds $Wait }   # no keys: just watch the game for -Wait ms
foreach ($k in $Keys) {
    $out = & "$PSScriptRoot\sendkeys.ps1" -Keys $k -DelayMs $Wait -Probe:$Probe -Post:$Post
    Write-Output $out
    if ($LASTEXITCODE -ne 0) { Write-Output "Run stopped."; exit $LASTEXITCODE }
}
Get-Content $log -Encoding UTF8 | Select-Object -Skip $before |
    Where-Object { $_ -match '\[Wandsong\] (say|ReadMenu .*\[open\]|click|unlabelled)|subtitles\] line|feedback\] prompt|Fatal|error' } |
    Select-Object -Last $Lines |
    ForEach-Object { $t = $_.Substring([Math]::Min(22, $_.Length)); $t.Substring(0, [Math]::Min(260, $t.Length)) }
